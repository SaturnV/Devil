#! /usr/bin/perl
###### NAMESPACE ##############################################################

package Devil::Tcp;

###### IMPORTS ################################################################

use Essence::Strict;

use parent 'Devil';

use AnyEvent::Socket;

###### METHODS ################################################################

sub _ClearConnection
{
  my ($self) = @_;

  $self->Warn("Throwing away read buffer")
    if (($self->{'read_buffer'} // '') ne '');
  $self->Warn("Throwing away write buffer")
    if (($self->{'write_buffer'} // '') ne '');

  undef($self->{$_})
    foreach (qw( connected_to socket
                 reader read_buffer
                 writer write_buffer ));
  $self->{'state'} = 'not_connected';
  $self->Reset('Connect');

  return $self;
}

sub _OnError
{
  $_[0]->_ClearConnection();
  return shift->next::method(@_);
}

# ---- Connect ----------------------------------------------------------------

# TODO _OnConnect?
sub _ConnectDevil
{
  my ($self, $host, $port) = @_;
  $host //= $self->{'host'};
  $port //= $self->{'port'};

  $self->{'state'} = 'connecting';

  tcp_connect($host, $port,
      sub
      {
        if (@_)
        {
          my ($fh) = @_;

          $self->{'connected_to'} = [$host, $port];
          $self->{'socket'} = $fh;
          $self->{'reader'} = AnyEvent->io(
              'fh' => $fh,
              'poll' => 'r',
              'cb' => sub { $self->_OnReadable() });
          $self->{'state'} = 'connected';

          $self->Deliver('Connect');
        }
        else
        {
          $self->{'state'} = 'connect_error';
          $self->_OnConnectError('connect', $!);
        }
      });

  return 'Connect';
}

sub _OnConnectError { return shift->_OnError('Connect', @_) }

sub Connect
{
  my $self = shift;
  $self->CallOrWait('Connect', @_)
    unless $self->{'socket'};
  return $self;
}

# ---- Read -------------------------------------------------------------------

sub read_chunk_size { return 4096 }
sub read_buffer_size { return 4096 }

sub _OnReadable
{
  my ($self) = @_;

  $self->{'read_buffer'} //= '';

  my $read = sysread(
      $self->{'socket'},
      $self->{'read_buffer'},
      $self->read_chunk_size(),
      length($self->{'read_buffer'}));
  return $self->_OnReadError('read', $!) unless defined($read);
  return $self->_OnEof() unless $read;
  return $self->_OnRead($read);
}

sub _OnReadError { return shift->_OnError(undef, @_) }

sub _OnRead
{
  my ($self) = @_;
  $self->_OnReadError('read', "Buffer overflow")
    if (length($self->{'read_buffer'}) > $self->read_buffer_size());
}

sub _OnEof
{
  my ($self) = @_;
  $self->LogInfo('EOF');
  $self->_ClearConnection();
}

# ---- Write ------------------------------------------------------------------
# TODO Low water mark

sub write_buffer_size { return 4096 }
sub write_chunk_size { return }

sub WriteNB
{
  # my ($self, $data) = @_;
  my $self = $_[0];

  if (defined($self->{'write_buffer'}))
  {
    $self->{'write_buffer'} .= $_[1];
  }
  elsif (($self->{'state'} //= 'not_connected') eq 'connecting')
  {
    $self->{'write_buffer'} = $_[1];
  }
  else
  {
    $self->Confess("Write on an unconnected socket")
      unless $self->{'socket'};

    my $to_write = length($_[1]);
    my $to_write_ = $self->write_chunk_size();
    $to_write_ = $to_write
      if (!defined($to_write_) || ($to_write < $to_write_));

    my $written = syswrite(
        $self->{'socket'}, $_[1], $to_write_);
    if (!defined($written) && !$!{'EAGAIN'})
    {
      $self->{'write_buffer'} = $_[1];
      return $self->_OnWriteError('write', $!);
    }
    elsif (($written //= 0) < $to_write)
    {
      $self->{'write_buffer'} = substr($_[1], $written);
      $self->{'writer'} = AnyEvent->io(
          'fd' => $self->{'socket'},
          'poll' => 'w',
          'cb' => sub { $self->_OnWritable() });
    }
  }

  return $self->_OnWriteError('write', "Buffer overflow")
    if (defined($self->{'write_buffer'}) &&
        (length($self->{'write_buffer'}) > $self->write_buffer_size()));

  return $self;
}

sub _OnWritable
{
  my ($self) = @_;

  $self->Confess("_OnWritable on an unconnected socket")
    unless $self->{'socket'};

  my $to_write = length($self->{'write_buffer'});
  my $to_write_ = $self->write_chunk_size();
  $to_write_ = $to_write
    if (!defined($to_write_) || ($to_write < $to_write_));

  my $written = syswrite(
      $self->{'socket'}, $self->{'write_buffer'}, $to_write_);
  if (!defined($written) && !$!{'EAGAIN'})
  {
    return $self->_OnWriteError('write', $!);
  }
  elsif (($written //= 0) < $to_write)
  {
    substr($self->{'write_buffer'}, 0, $written, '')
      if $written;
  }
  else
  {
    undef($self->{'write_buffer'});
    undef($self->{'writer'});
  }
}

sub _OnWriteError { return shift->_OnError(undef, @_) }

###############################################################################

1
