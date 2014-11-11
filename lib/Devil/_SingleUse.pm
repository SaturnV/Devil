#! /usr/bin/perl
package Devil::_SingleUse;

use Essence::Strict;

use parent 'Devil::_Condition';

sub Expired { return 1 }

1
