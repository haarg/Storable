#!./perl -w
#
#  Copyright 2002, Larry Wall.
#
#  You may redistribute only under the same terms as Perl 5, as specified
#  in the README file that comes with the distribution.
#

# I ought to keep this test easily backwards compatible to 5.004, so no
# qr//;

# This test checks downgrade behaviour on pre-5.8 perls when new 5.8 features
# are encountered.

sub BEGIN {
    if ($ENV{PERL_CORE}){
	chdir('t') if -d 't';
	@INC = ('.', '../lib');
    } else {
	unshift @INC, 't';
    }
    require Config; import Config;
    if ($ENV{PERL_CORE} and $Config{'extensions'} !~ /\bStorable\b/) {
        print "1..0 # Skip: Storable was not built\n";
        exit 0;
    }
}

use Test::More;
use Storable qw (dclone store retrieve freeze thaw nstore nfreeze);
use strict;

my $max_uv = ~0;
my $max_uv_m1 = ~0 ^ 1;
# Express it in this way so as not to use any addition, as 5.6 maths would
# do this in NVs on 64 bit machines, and we're overflowing IVs so can't use
# use integer.
my $max_iv_p1 = $max_uv ^ ($max_uv >> 1);
my $lots_of_9C = do {
  my $temp = sprintf "%X", ~0;
  $temp =~ s/FF/9C/g;
  local $^W;
  hex $temp;
};

my $max_iv = ~0 >> 1;
my $min_iv = do {use integer; -$max_iv-1}; # 2s complement assumption

my @processes = (["dclone", \&do_clone],
                 ["freeze/thaw", \&freeze_and_thaw],
                 ["nfreeze/thaw", \&nfreeze_and_thaw],
                 ["store/retrieve", \&store_and_retrieve],
                 ["nstore/retrieve", \&nstore_and_retrieve],
                );
my @numbers =
  (# IV bounds of 8 bits
   -1, 0, 1, -127, -128, -129, 42, 126, 127, 128, 129, 254, 255, 256, 257,
   # IV bounds of 32 bits
   -2147483647, -2147483648, -2147483649, 2147483646, 2147483647, 2147483648,
   # IV bounds
   $min_iv, do {use integer; $min_iv + 1}, do {use integer; $max_iv - 1},
   $max_iv,
   # UV bounds at 32 bits
   0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xDEADBEEF,
   # UV bounds
   $max_iv_p1, $max_uv_m1, $max_uv, $lots_of_9C,
  );

plan tests => @processes * @numbers * 5;

my $file = "integer.$$";
die "Temporary file '$file' already exists" if -e $file;

END { while (-f $file) {unlink $file or die "Can't unlink '$file': $!" }}

sub do_clone {
  my $data = shift;
  my $copy = eval {dclone $data};
  is ($@, '', 'Should be no error dcloning');
  ok (1, "dlcone is only 1 process, not 2");
  return $copy;
}

sub freeze_and_thaw {
  my $data = shift;
  my $frozen = eval {freeze $data};
  is ($@, '', 'Should be no error freezing');
  my $copy = eval {thaw $frozen};
  is ($@, '', 'Should be no error thawing');
  return $copy;
}

sub nfreeze_and_thaw {
  my $data = shift;
  my $frozen = eval {nfreeze $data};
  is ($@, '', 'Should be no error nfreezing');
  my $copy = eval {thaw $frozen};
  is ($@, '', 'Should be no error thawing');
  return $copy;
}

sub store_and_retrieve {
  my $data = shift;
  my $frozen = eval {store $data, $file};
  is ($@, '', 'Should be no error storing');
  my $copy = eval {retrieve $file};
  is ($@, '', 'Should be no error retrieving');
  return $copy;
}

sub nstore_and_retrieve {
  my $data = shift;
  my $frozen = eval {nstore $data, $file};
  is ($@, '', 'Should be no error storing');
  my $copy = eval {retrieve $file};
  is ($@, '', 'Should be no error retrieving');
  return $copy;
}

foreach (@processes) {
  my ($process, $sub) = @$_;
  foreach my $number (@numbers) {
    # as $number is an alias into @numbers, we don't want any side effects of
    # conversion macros affecting later runs, so pass a copy to Storable:
    my $copy1 = my $copy0 = $number;
    my $copy_s = &$sub (\$copy0);
    if (is (ref $copy_s, "SCALAR", "got back a scalar ref?")) {
      # Test inside use integer to see if the bit pattern is identical
      # and outside to see if the sign is right.
      # On 5.8 we don't need this trickery anymore.
      # We really do need 2 copies here, as conversion may have side effect
      # bugs. In particular, I know that this happens:
      # perl5.00503 -le '$a = "-2147483649"; $a & 0; print $a; print $a+1'
      # -2147483649
      # 2147483648

      my $copy_s1 = my $copy_s2 = $$copy_s;
      # On 5.8 can do this with a straight ==, due to the integer/float maths
      # on 5.6 can't do this with
      # my $eq = do {use integer; $copy_s1 == $copy1} && $copy_s1 == $copy1;
      # because on builds with IV as long long it tickles bugs.
      # (Uncomment it and the Devel::Peek line below to see the messed up
      # state of the scalar, with PV showing the correct string for the
      # number, and IV holding a bogus value which has been truncated to 32 bits

      # So, check the bit patterns are identical, and check that the sign is the
      # same. This works on all the versions in all the sizes.
      # $eq =  && (($copy_s1 <=> 0) == ($copy1 <=> 0));
      # Split this into 2 tests, to cater for 5.005_03

      my $bit =  ok (($copy_s1 ^ $copy1 == 0), "$process $copy1 (bitpattern)");
      # This is sick. 5.005_03 survives without the IV/UV flag, and somehow
      # gets it right, providing you don't have side effects of conversion.
#      local $TODO;
#      $TODO = "pre 5.6 doesn't have flag to distinguish IV/UV"
#        if $[ < 5.005_56 and $copy1 > $max_iv;
      my $sign = ok (($copy_s2 <=> 0) == ($copy1 <=> 0),
                     "$process $copy1 (sign)");

      unless ($bit and $sign) {
        printf "# Passed in %s  (%#x, %i)\n# got back '%s' (%#x, %i)\n",
          $copy1, $copy1, $copy1, $copy_s1, $copy_s1, $copy_s1;
        # use Devel::Peek; Dump $copy_s1; Dump $$copy_s;
      }
      # unless ($bit) { use Devel::Peek; Dump $copy_s1; Dump $$copy_s; }
    } else {
      fail ("$process $copy1");
      fail ("$process $copy1");
    }
  }
}
