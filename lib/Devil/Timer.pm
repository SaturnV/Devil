#! /usr/bin/perl

package Devil::Timer;

use Essence::Strict;

use base 'Devil';

use AnyEvent;

sub new
{
  my ($class, $timeout) = @_;
  my $self = bless({}, $class);

  $self->Recurring('Timer');
  $self->{'timer'} =
      AnyEvent->timer(
          'after' => $timeout,
          'interval' => $timeout,
          'cb' => sub { $self->Deliver('Timer') })
    if $timeout;

  return $self;
}

1
