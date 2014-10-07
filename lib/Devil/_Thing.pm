#! /usr/bin/perl

package Devil::_Thing;

use Essence::Strict;

# $thing = $class->new($name, $parent)
sub new { return bless([], $_[0]) }

# Called during $devil->WaitFor*()
# $ready = $thing->Ready()
sub Ready { return scalar(@{$_[0]}) }

# Called during $devil->WaitFor*()
# $wrap = $thing->Get()
# sub Get { return }

# Called during $devil->WaitFor*()
sub OnDelivery { return $_[0] }

# Called during $devil->Deliver()
# $thing->Put($wrap)
# sub Put { return $_[0] }

# $thing->Reset();
sub Reset { splice(@{$_[0]}) ; return $_[0] }

# $expired = $thing->Expired()
sub Expired { return }

1
