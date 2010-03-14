# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl WEC-PlRPC.t'
#########################

use Test::More tests => 2;
BEGIN { use_ok('WEC::PlRPC::Client') };
BEGIN { use_ok('WEC::PlRPC::Server') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

