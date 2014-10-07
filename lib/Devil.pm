#! /usr/bin/perl
# Devil: (noun) an instrument or machine fitted with sharp teeth or spikes,
#     used for tearing or other destructive work.
###### NAMESPACE ##############################################################

package Devil;

###### IMPORTS ################################################################

use Essence::Strict;

use base 'Essence::Logger::Mixin';

use Coro;
use Coro::Channel;
use AnyEvent;

use Tie::IxHash;
use List::Util qw( first );
use List::MoreUtils qw( any none );

use Devil::_Condition;
use Devil::_Recurring;
use Devil::_SingleUse;
use Devil::_Queue;

###### VARS ###################################################################

# $Channels->{$coro} = Coro::Channel
our $Channels;

# $Subscribers->{'event'}->{$coro} = Tie::IxHash 'id' => $cb
our $Subscribers;

###### METHODS ################################################################

# ==== Coro interaction =======================================================

sub initialize_coro
{
  my ($class, @coros) = @_;

  push(@coros, $Coro::current)
    unless @coros;

  foreach my $coro (@coros)
  {
    delete($Channels->{$coro}) if $Channels;
    $class->unsubscribe_coro($coro) if $Subscribers;
  }

  return $class;
}

sub cleanup_coro
{
  my ($class, @coros) = @_;

  push(@coros, $Coro::current)
    unless @coros;

  foreach my $coro (@coros)
  {
    my $channel;
    $channel = delete($Channels->{$coro}) if $Channels;
    $class->Warn("Destroying a coro that had messages left.\n")
      if ($channel && $channel->size());

    $class->unsubscribe_coro($coro) if $Subscribers;
  }

  return $class;
}

sub subscribe
{
  my ($class, $event, $id, $cb) = @_;

  $Subscribers //= {};
  my $coros = $Subscribers->{$event} //= {};
  my $subscribers_here = $coros->{$Coro::current} //= Tie::IxHash->new();
  $subscribers_here->Push($id => $cb);

  $Channels->{$Coro::current} //= Coro::Channel->new();

  return $class;
}

sub unsubscribe
{
  my ($class, $event, $id) = @_;
  my $cb;

  if ($Subscribers)
  {
    if (my $coros = $Subscribers->{$event})
    {
      if (my $subscribers_here = $coros->{$Coro::current})
      {
        $cb = $subscribers_here->Delete($id);

        if (!$subscribers_here->Length())
        {
          delete($coros->{$Coro::current});
          delete($Subscribers->{$event})
            unless %{$coros};
        }
      }
    }
  }

  return $cb;
}

sub unsubscribe_coro
{
  my ($self, $coro) = @_;
  my $n = 0;

  if ($Subscribers)
  {
    my $event_subscribers;
    my @events = keys(%{$Subscribers});
    foreach my $event (@events)
    {
      $event_subscribers = $Subscribers->{$event};
      if (delete($event_subscribers->{$coro}))
      {
        delete($Subscribers->{$event})
          unless %{$event_subscribers};
        $n++;
      }
    }
  }

  return $n;
}

sub trigger
{
  my ($class, $event) = (shift, shift);
  my $n = 0;

  if ($Subscribers)
  {
    if (my $coros = $Subscribers->{$event})
    {
      if (my $subscribers_here = $coros->{$Coro::current})
      {
        foreach my $id ($subscribers_here->Keys())
        {
          $subscribers_here->FETCH($id)->($event, $id, @_);
          $n++;
        }
      }
    }
  }

  return $n;
}

sub signal
{
  my ($class, $event) = (shift, shift);

  if ($Subscribers)
  {
    if (my $coros = $Subscribers->{$event})
    {
      my $my_coro = "$Coro::current";
      foreach my $coro (keys(%{$coros}))
      {
        if ($coro eq $my_coro)
        {
          $class->trigger($event, @_);
        }
        elsif ($Channels && $Channels->{$coro})
        {
          $Channels->{$coro}->put(['event', $event, @_]);
        }
        else
        {
          $class->Warn(
              "A coro is subscribed for '$event' but has no channel.");
        }
      }
    }
  }

  return $class;
}

# ==== Timer ==================================================================

sub timer
{
  my ($self, @args) = @_;

  my ($after, $interval, $cb);
  while (@args)
  {
    given (shift(@args))
    {
      when ('after')
      {
        $self->Carp("Multiple timeouts for timer")
          if defined($after);
        $after = shift(@args);
      }
      when ('interval')
      {
        $self->Carp("Multiple intervals for timer")
          if defined($interval);
        $interval = shift(@args);
      }
      when ('cb')
      {
        $self->Carp("Multiple callbacks for timer")
          if defined($cb);
        $cb = shift(@args);
      }
      default
      {
        $self->Carp("Bad timer parameter '$_'");
      }
    }
  }
  $self->Carp("Timer without timeout")
    unless (defined($after) || defined($interval));
  $self->Carp("Timer without callback")
    unless defined($cb);

  my $channel = $Channels->{$Coro::current} //= Coro::Channel->new();

  my @timer = ( 'cb' => sub { $channel->put(['call', $cb]) } );
  push(@timer, 'after' => $after) if defined($after);
  push(@timer, 'interval' => $interval) if defined($interval);
  return AnyEvent->timer(@timer);
}

# ==== Wait / Deliver =========================================================

# ---- Pledge -----------------------------------------------------------------

sub _Pledge
{
  my ($self, $class) = (shift, shift);

  my $pending = $self->{'Devil::Things'} //= {};
  foreach my $thing (@_)
  {
    $self->Croak("Re-inventing thing '$thing'")
      if $pending->{$thing};
    $pending->{$thing} = $class->new($thing, $self);
  }

  return $self;
}

sub _RePledge
{
  my ($self, $class) = (shift, shift);

  my $pending = $self->{'Devil::Things'} //= {};
  foreach my $thing (@_)
  {
    if ($pending->{$thing})
    {
      $self->Croak("Re-inventing thing '$thing'")
        unless $pending->{$thing}->isa($class);
      $pending->{$thing}->Reset()
    }
    else
    {
      $pending->{$thing} = $class->new($thing, $self);
    }
  }

  return $self;
}

sub SingleUse { return shift->_Pledge('Devil::_SingleUse', @_) }
sub Condition { return shift->_Pledge('Devil::_Condition', @_) }
sub Recurring { return shift->_Pledge('Devil::_Recurring', @_) }
sub Queue { return shift->_Pledge('Devil::_Queue', @_) }

# No ReSingleUse
sub ReCondition { return shift->_RePledge('Devil::_Condition', @_) }
sub ReRecurring { return shift->_RePledge('Devil::_Recurring', @_) }
sub ReQueue { return shift->_RePledge('Devil::_Queue', @_) }

sub OnceAgain
{
  my $self = shift;
  my $seqs = $self->{'Devil::SequenceNumbers'} //= {};
  my @things =
      map { $seqs->{$_} //= 0 ; $_ . '[' . $seqs->{$_}++ . ']' } @_;
  $self->SingleUse(@things);
  return @things if wantarray;
  return $things[-1];
}

# ---- Query ------------------------------------------------------------------

sub IsInProgress
{
  # my ($self, $thing) = @_;
  my $t;
  return !!(($t = $_[0]->{'Devil::Things'}) && $t->{$_[1]});
}

sub IsAvailable
{
  # my ($self, $thing) = @_;
  my $t;
  return (($t = $_[0]->{'Devil::Things'}) &&
          ($t = $t->{$_[1]}) &&
           $t->Ready());
}

# ---- Wait -------------------------------------------------------------------

sub _Wait
{
  my $self = shift;

  my $waiting = $self->{'Devil::WaitingCoros'} //= {};
  my $me = $waiting->{$Coro::current} //= {};
  foreach (@_)
  {
    $me->{$_} //= 0;
    $me->{$_}++;
  }

  return $self;
}

sub _Unwait
{
  my $self = shift;

  if (my $waiting = $self->{'Devil::WaitingCoros'})
  {
    if (my $me = $waiting->{$Coro::current})
    {
      foreach (@_)
      {
        delete($me->{$_})
          unless (--$me->{$_} > 0);
      }

      delete($waiting->{$Coro::current})
        unless %{$me};
    }
  }

  return $self;
}

sub _Expire
{
  my ($self, $thing) = @_;

  my $t;
  if ((!($t = $self->{'Devil::WaitingCoros'}) || !%{$t} ||
       (none { $_->{$thing} } values(%{$t}))) &&
      ($t = $self->{'Devil::Things'}) && ($t = $t->{$thing}))
  {
    if ($t->Expired())
    {
      $self->Remove($thing);
    }
    else
    {
      $t->OnDelivery();
    }
  }

  return $self;
}

sub WaitForAny
{
  my ($self, @things) = @_;

  # $self->LogDebug("WaitForAny [$Coro::current]", $self, \@things);

  $self->Croak("Waiting for nothing") unless @things;

  my $pending = $self->{'Devil::Things'};
  $self->Croak("Waiting for a wonder")
    unless $pending;

  my %things;
  foreach (@things)
  {
    $self->Carp("Redundantly waiting for '$_'")
      if $things{$_};
    $self->Croak("Waiting for a wonder called '$_'")
      unless $pending->{$_};
    $things{$_} = 1;
  }

  $self->_Wait(@things);

  my $thing;
  eval
  {
    my ($msg, $msg_type, @removed);
    my $channel = $Channels->{$Coro::current} //= Coro::Channel->new();
    until (defined($thing = first { $pending->{$_}->Ready() } @things))
    {
      # $self->LogDebug("WaitFor block [$Coro::current]");
      $msg = $channel->get();
      # $self->LogDebug("WaitFor unblock [$Coro::current]", $msg);
      $self->Die("Received an invalid event notification.")
        unless (ref($msg) eq 'ARRAY');

      $msg_type = shift(@{$msg});
      if ($msg_type eq 'call')
      {
        shift(@{$msg})->(@{$msg});
      }
      elsif ($msg_type eq 'event')
      {
        $self->trigger(@{$msg});
      }
      elsif ($msg_type ne 'delivery')
      {
        $self->Die("Bad message type", $msg_type);
      }

      # Check removed things
      if (@removed = grep { !$pending->{$_} } @things)
      {
        $self->Warn("Vanished: " . join(', ', @removed));
        delete($things{$_}) foreach (@removed);
        $self->_Unwait(@removed);
        @things = keys(%things) or
          $self->Die("Everything disappeared.\n");
      }
    }
    # $self->LogDebug("WaitFor: received $thing");
  };
  if (my $err = $@)
  {
    $self->_Unwait(@things);
    die $err;
  }

  my $result = $pending->{$thing}->Get();
  $self->_Unwait(@things);
  $self->_Expire($thing);
  die @{$result} if (ref($result) eq 'Devil::Exception');

  # $self->LogDebug("WaitForAny [$Coro::current] -> $thing", $self, $result);

  return ($thing, @{$result}) if wantarray;
  return $thing;
}

sub WaitForAll
{
  my ($self, @things) = @_;
  my %got;

  my %expecting;
  foreach (@things)
  {
    $self->Carp("Redundantly waiting for '$_'")
      if $expecting{$_};
    $expecting{$_} = 1;
  }

  while (%expecting)
  {
    my ($thing, @results) = $self->WaitForAny(keys(%expecting));
    $got{$thing} = \@results;
    delete($expecting{$thing});
  }

  return \%got;
}

sub WaitFor
{
  # my ($self, $thing) = @_;
  my (undef, @ret) = shift->WaitForAny(@_);
  return @ret if wantarray;
  return $ret[0];
}

# ---- Deliver ----------------------------------------------------------------

sub _Deliver
{
  my ($self, $thing, $stuff) = @_;

  my $pending = $self->{'Devil::Things'};
  $self->Confess("Nobody is waiting for '$thing'")
    unless ($pending && $pending->{$thing});
  $pending->{$thing}->Put($stuff);

  if (my $waiting = $self->{'Devil::WaitingCoros'})
  {
    foreach my $coro (keys(%{$waiting}))
    {
      if ($waiting->{$coro}->{$thing})
      {
        if ($Channels->{$coro})
        {
          $Channels->{$coro}->put(['delivery', $thing]);
        }
        else
        {
          $self->Warn("$coro is waiting for '$thing' but has no channel.");
        }
      }
    }
  }

  return @_ if wantarray;
  return $_[0];
}

sub Deliver { return shift->_Deliver(shift, [@_]) }
sub Kill { return shift->_Deliver(shift, bless([@_], 'Devil::Exception')) }

# -----------------------------------------------------------------------------

sub Reset
{
  my $self = shift;

  my $pending = $self->{'Devil::Things'} or
    $self->Croak("No things");

  foreach my $thing (@_)
  {
    $self->Croak("Resetting no-thing '$thing'")
      unless $pending->{$thing};
    $pending->{$thing}->Reset();
  }

  return $self;
}

sub Remove
{
  my $self = shift;

  my $pending = $self->{'Devil::Things'} or
    $self->Croak("No things");

  my $waiting = $self->{'Devil::WaitingCoros'};
  foreach my $thing (@_)
  {
    $self->Carp("Removing no-thing '$thing'")
      unless $pending->{$thing};
    $self->Carp("Removing active thing '$thing'")
      if ($waiting &&
          (any { $_->{$thing} } values(%{$waiting})));
    delete($pending->{$thing});
  }

  return $self;
}

# ---- CallOrWait -------------------------------------------------------------

sub CallOrWait
{
  my ($self, $thing) = (shift, shift);

  $self->Condition($thing)
    unless $self->IsInProgress($thing);

  if (!$self->IsAvailable($thing))
  {
    my $method = "_${thing}Devil";
    $self->$method(@_);
  }

  return $self->WaitFor($thing);
}

# ==== Error Handling =========================================================

sub _MakeException
{
  my ($self, $thing, $op, $msg) = @_;
  $msg //= 'Something went wrong.';
  $msg = "$op: $msg" if defined($op);
  $msg = "($thing) $msg" if defined($thing);
  return ($msg);
}

sub _OnError
{
  # my ($self, $thing, $op, $error) = @_;
  my ($self, $thing) = @_;
  my @exception = shift->_MakeException(@_);
  defined($thing) ?
      $self->Kill($thing, @exception) :
      $self->Die(@exception)
    if @exception;
}

###############################################################################

1
