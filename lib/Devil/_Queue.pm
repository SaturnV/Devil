#! /usr/bin/perl

package Devil::_Queue;

use Essence::Strict;

use parent 'Devil::_Thing';

sub Get { return shift(@{$_[0]}) }
sub Put { push(@{$_[0]}, $_[1]) ; return $_[0] }

1
