#! /usr/bin/perl
# Like Condition, but is Reset by Get.

package Devil::_Recurring;

use Essence::Strict;

use base 'Devil::_Condition';

sub Get { return shift(@{$_[0]}) }

1
