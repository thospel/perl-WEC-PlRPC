package WEC::PlRPC::Client;
use 5.006;
use strict;
use warnings;
use Carp;

use WEC::PlRPC::Connection;

our $VERSION = "0.01";
our @CARP_NOT	= qw(WEC::FieldClient);

use base qw(WEC::Client);

my $default_options = {
    %{__PACKAGE__->SUPER::client_options},
    Reject	=> undef,
    InCipher	=> undef,
    OutCipher	=> undef,
    Cipher	=> undef,
    Compression	=> undef,
    Application	=> undef,
    Version	=> undef,
    User	=> undef,
    Password	=> undef,
    MaxMessage	=> 2**16,
};

sub default_options {
    return $default_options;
}

sub connection_class {
    return "WEC::PlRPC::Connection";
}

sub init {
    my ($client, $params) = @_;
    my $options = $client->{options};
    defined $options->{Application}	|| croak "No Application specified";
    defined $options->{Version}		|| croak "No Version specified";
    if ($options->{Compression}) {
        my $comp = uc($options->{Compression});
        if ($comp eq "GZIP") {
	    require Compress::Zlib;
        } else {
            croak "Unknown compression method '$client->{options}{Compression}'";
        }
    }
    if (defined(my $cipher = delete $params->{Cipher})) {
        croak "Both InCipher and Cipher"  if defined $options->{InCipher};
        croak "Both OutCipher and Cipher" if defined $options->{OutCipher};
        $options->{InCipher} = $options->{OutCipher} = $cipher;
    }
    $options->{InBlockSize} = $options->{InCipher}->blocksize if 
        $options->{InCipher};
    $options->{OutBlockSize} = $options->{OutCipher}->blocksize if 
        $options->{OutCipher};
}

sub connect : method {
    my $client = shift;
    my $connection = $client->SUPER::connect(@_);
    $connection->send([@{$client->{options}}{qw(Application Version User Password)}]);
    return $connection;
}

1;
__END__
