#! /usr/bin/perl
# Holds one value.
# Becomes Ready upon Put, remains Ready until Reset.
# Repeated Gets return that same value many times.

package Devil::_Condition;

use Essence::Strict;

use parent 'Devil::_Thing';

sub Get { return $_[0]->[0] }
sub Put { $_[0]->[0] = $_[1] ; return $_[0] }

sub OnDelivery
{
  $_[0]->Reset()
    if (@{$_[0]} && (ref($_[0]->[0]) eq 'Devil::Exception'));
  return $_[0];
}

1
