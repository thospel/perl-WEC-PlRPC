package WEC::PlRPC::Connection;
use 5.006;
use strict;
use warnings;
use Carp;

use Scalar::Util qw(weaken);
use Storable qw(nfreeze thaw);

use WEC::Connection qw(SERVER CLIENT);

our $VERSION = "1.000";

use base qw(WEC::Connection);
# use fields qw(greet objects);

our @CARP_NOT	= qw(WEC::FieldConnection);

sub REC_LEN()	{ 4 };

sub init_server {
    my $connection = shift;
    $connection->{host_mpx}	= 0;
    $connection->{peer_mpx}	= 0;
    $connection->{in_want}	= REC_LEN;
    $connection->{in_process}	= \&message_header;
    $connection->{greet}	= 1;
    $connection->begin_handshake;
}

sub init_client {
    my $connection = shift;
    $connection->{host_mpx}	= 0;
    $connection->{peer_mpx}	= 0;
    $connection->{in_want}	= REC_LEN;
    $connection->{in_process}	= \&message_header;
    $connection->{greet}	= 1;
    $connection->begin_handshake;
}

sub message_header {
    my $connection = shift;
    $connection->{in_want} = unpack("N", substr($_, 0,
                                                $connection->{in_want}, ""));
    croak "Incoming message size $connection->{in_want} exceeds Maximum message size $connection->{options}{MaxMessage}" if $connection->{in_want} > $connection->{options}{MaxMessage};
    $connection->{in_process}	= \&message_body;
}

sub message_body {
    my $connection = shift;
    my $length = $connection->{in_want};
    $connection->{in_want}	= REC_LEN;
    $connection->{in_process}	= \&message_header;

    my $encoded;
    if (my $in_cipher = $connection->{options}{InCipher}) {
        $encoded = "";
	my $size = $connection->{options}{InBlockSize};
        my $i = 0;
        for ($i = 0; $i < $length; $i += $size) {
            $encoded .= $in_cipher->decrypt(substr($_, $i, $size));
        }
        substr($_, 0, $i) = "";
        substr($encoded, $length) = "";
    } else {
        $encoded = substr($_, 0, $length, "");
    }
    $encoded = Compress::Zlib::uncompress($encoded) if
        $connection->{options}{Compression};
    my $decoded = thaw($encoded);
    if ($connection->{direction} & SERVER) {
        my $options = $connection->{options};
        if ($connection->{greet}) {
            croak "Expected PlRPC client to greet with an array reference"
                unless ref($decoded) eq "ARRAY";
            croak "Expected PlRPC client to greet with a 4 element array, not @$decoded"
                unless @$decoded == 4;
            my ($app, $version, $user, $pass) = @$decoded;
            unless ($options->{AcceptApplication} ?
                    $options->{AcceptApplication}->($connection, $options->{Application}, $app):
                    UNIVERSAL::isa($app, ref($connection))) {
                $connection->send_close([0, "This is a " . 
                                         ref($connection) . ", go away!"]);
                return;
            }
            unless ($options->{AcceptVersion} ?
                    $options->{AcceptVersion}->($connection, $options->{Version}, $version):
                    $version <= $options->{Version}) {
                $connection->send_close([0, "Sorry, but I am not running version $version."]);
                return;
            }
            my $result = $options->{AcceptUser} ?
                    $options->{AcceptUser}->($connection, $options->{Version}, $user, $pass):
                    1;
            unless ($result) {
                $connection->send_close([0, "User $user is not permitted to connect."]);
                return;
            }
            $connection->end_handshake;
            $connection->send(ref($result) ? $result : [1, "Welcome!"]);
            $connection->{greet} = 0;
            return;
        }
        my @result = eval {
            die "Expected PlRPC client to send an array reference\n"
                unless ref($decoded) eq "ARRAY";
            defined(my $command = shift @$decoded) ||
                die "Expected a defined method name\n";
            die "Expected a plain string as method name\n" if ref($command);
            my $commands = $options->{Methods}{$options->{Application}};
            die "Not permitted for method $command of class $options->{Application}\n" unless $commands && $commands->{$command};
            return $connection->$command(@$decoded);
        };
        if ($@) {
            my $err = $@;
            chop $err;
            $connection->send(\$err);
        } else {
            $connection->send(\@result);
        }
        return;
    }
    if ($connection->{greet}) {
        croak "Expected PlRPC server to greet with an array reference" unless
            ref($decoded) eq "ARRAY";
        if ($decoded->[0]) {
            $connection->end_handshake;
            $connection->{greet} = 0;
            $connection->{options}{Greeting}->($connection, $decoded->[1]) if
                $connection->{options}{Greeting};
        } elsif ($connection->{options}{Reject}) {
            $connection->{options}{Reject}->($connection, $decoded->[1]);
            $connection->_close("reject");
        } elsif (defined($decoded->[1]) && $decoded->[1] ne "") {
            warn("Connection rejected: $decoded->[1]\n");
            $connection->_close("rejected");
        } else {
            warn("Connection rejected without message");
            $connection->_close("rejected");
        }
        return;
    }
    my $action = shift @{$connection->{answers}} ||
        croak "Unsolicited incoming message";
    my $callback = shift @{$connection->{answers}};
    if ($action eq "DH") {
        warn("\t(in PlRPC object cleanup) $$decoded\n") if
            ref($decoded) eq "SCALAR";
        return;
    }
    die "PlRPC server returned error: $$decoded\n" if
        ref($decoded) eq "SCALAR";
    croak "Expected PlRPC server to answer with an array reference"
        unless ref($decoded) eq "ARRAY";
    if ($action eq "CO") {
        croak "PlRPC server did not answer with a length 1 array reference" unless @$decoded == 1;
        croak "ClientObject should be an identifier string, not a reference" if ref($decoded->[0]);
        $decoded->[0] =~ /^((?:\w+|::)+)=\w+\(0x[\da-f]+\)\z/ ||
            croak "PlRPC server did not return an object but '$decoded->[0]'";
        # We don't actually have to build a fake class, but it makes
        # debugging easier
        my $class = "WEC::PlRPC::Proxy::$1";
        no strict 'refs';
        unless (@{"${class}::ISA"}) {
            @{"${class}::ISA"}	= "WEC::PlRPC::Proxy";
            @{"${class}::CARP_NOT"}	= qw(WEC::PlRPC::Connection);
        }
        my $proxy = bless [$connection, $decoded->[0]], $class;
        weaken($proxy->[0]);
        $callback->($proxy);
    } elsif ($action eq "CM") {
        $callback->(@$decoded) if $callback;
    } else {
        croak "Unknown action $action";
    }
}

# Call as $conn->send($data_ref)
sub send : method {
    my $connection = shift;
    die "Attempt to send on a closed Connection" unless 
        $connection->{out_handle};
    my $encoded = nfreeze(shift);
    $encoded = Compress::Zlib::compress($encoded) if
        $connection->{options}{Compression};
    my $length = length($encoded);
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= pack("N", $length);
    if (my $out_cipher = $connection->{options}{OutCipher}) {
	my $size = $connection->{options}{OutBlockSize};
        $encoded .= chr(0) x (-$length % $size) if $length % $size;
	for (my $i = 0;  $i < $length;  $i += $size) {
	    $connection->{out_buffer} .=
                $out_cipher->encrypt(substr($encoded, $i, $size));
	}
    } else {
        $connection->{out_buffer} .= $encoded;
    }
    # This should be impossible. freeze, gzip and crypt should give bytes
    die "Assertion: Output buffer is utf8" if 
        utf8::is_utf8($connection->{out_buffer});
    # return;
}

sub _close {
    my $connection = shift;
    $connection->{answers}  = undef;
    $connection->{objects} = undef;
    $connection->SUPER::_close(@_);
}

sub ClientObject {
    my $connection = shift;
    push @{$connection->{answers}}, "CO", shift;
    $connection->send(["NewHandle", @_]);
}

sub NewHandle {
    my $connection = shift;
    # Untaint class and method so we won't get tainted objects. 
    # Should be ok since we will check if you may use them anyways
    my ($class)  = shift =~ /(.*)/s;
    my ($method) = shift =~ /(.*)/s;
    my $methods = $connection->{options}{Methods}{$class};
    die "Not permitted for method $method of class $class\n" unless
        $methods && $methods->{$method};
    my $object = $class->$method(@_) ||
        die "Constructor $method didn't return a true value\n";
    my $object_str = "$object";
    $connection->{"objects"}{$object_str} = $object;
    return $object_str;
}

sub CallMethod {
    my $connection = shift;
    my $object_str = shift;
    my $method	   = shift;
    # die "CallMethod called on a real reference\n" if ref($object_str) ne "";
    my $object = $connection->{objects}{$object_str} ||
        die "No such object '$object_str'\n";
    my $methods = $connection->{options}{Methods}{ref $object};
    die "Not permitted for method $method of class ", ref $object, "\n" unless
        $methods && $methods->{$method};
    return $object->$method(@_);
}

sub DestroyHandle {
    my $connection = shift;
    my $object_str = shift;
    delete $connection->{objects}{$object_str} ||
        die "No such object '$object_str'\n";
    return;
}


package WEC::PlRPC::Proxy;
our $VERSION = "1.000";
our $AUTOLOAD;

sub AUTOLOAD {
    my $method = $AUTOLOAD;
    $method =~ s/(.*):://sg || Carp::croak("Cannot parse method '$method'");
    my $class = $1;
    eval <<"EOM";
        package $class;
        sub $method {
            my \$self = shift;
            my WEC::PlRPC::Connection \$connection = \$self->[0] ||
                Carp::croak("Underlying connection object is gone");
            \$connection->{out_handle} ||
                Carp::croak("Underlying connection is closed");
            push \@{\$connection->{answers}}, "CM", shift;
            \$connection->send(['CallMethod', \$self->[1], '$method', \@_]);
        }
EOM
    die $@ if $@;
    goto &$AUTOLOAD;
}

sub DESTROY {
    my $self = shift;
    my WEC::PlRPC::Connection $connection = $self->[0] || return;
    $connection->{out_handle} || return;
    push @{$connection->{answers}}, "DH", undef;
    $connection->send(["DestroyHandle", $self->[1]]) if
        $connection->{in_handle};
}

1;
