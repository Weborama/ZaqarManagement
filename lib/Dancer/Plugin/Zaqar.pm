package Dancer::Plugin::Zaqar;

# ABSTRACT: Easy management of Zaqar connections

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use Dancer qw/:syntax/;
use Dancer::Exception qw/:all/;
use Dancer::Plugin;
use File::ShareDir;
use WebService::Zaqar;

our $handles;

register_exception('ZaqarException');

register 'queue_server' => sub {
    my $handle_name = shift // 'default';

    # do as DBIx::Connector does
    my $pid_tid = $$;
    $pid_tid .= '_' . threads->tid if $INC{'threads.pm'};

    my $zaqar;
    if ($zaqar = $handles->{$pid_tid}->{$handle_name}) {
        # got one already
    } else {
        # build new one
        my $plugin_config = plugin_setting;
        unless (exists $plugin_config->{$handle_name}) {
            die "No config for Zaqar server '$handle_name'";
        }
        my $config = $plugin_config->{$handle_name};
        try {
            $zaqar = WebService::Zaqar->new(base_url => $config->{base_url},
                                            wants_auth => $config->{wants_auth},
                                            spore_description_file => File::ShareDir::dist_file('WebService-Zaqar', 'marconi.spore.json'),
                                            (rackspace_keystone_endpoint => $config->{auth_host}) x!! $config->{auth_host},
                                            (rackspace_username => $config->{username}) x!! $config->{username},
                                            (rackspace_api_key => $config->{api_key}) x!! $config->{api_key});
        } catch {
            my $error = $_;
            raise 'ZaqarException' => "Could not connect to queue server: $error";
        };
        $handles->{$pid_tid}->{$handle_name} = $zaqar;
    }

    return $zaqar;

};

register_plugin;

1;
__END__
=pod

=head1 SYNOPSIS

  # in your Dancer app
  use Dancer::Plugin::WindtrapQueueServer;
  queue_server->publish($routing_key, $blob);

=head1 DESCRIPTION

This Dancer plugin handles connection configuration and
fork-and-thread-safety for L<Weborama::Windtrap::QueueServer>
instances.  Like its backend, it is well suited for simple queuing
tasks.  For more details on what this means for applications, see the
documentation in L<Weborama::Windtrap::QueueServer>.

=head1 KEYWORDS

L<Dancer::Plugin::WindtrapQueueServer> exports a single keyword.

=head2 queue_server

  my $default_queue_server = queue_server;
  my $other_queue_server = queue_server('other');

This keyword returns an instance of L<Weborama::Windtrap::QueueServer>
with the configuration specified in the standard Dancer way (see
L</CONFIGURATION>).  If the current process already has a valid
instance, that one is returned instead.

=head1 CONFIGURATION

  plugins:
    WindtrapQueueServer:
      default:
        host: ZAQAR_BASE_URL
        wants_auth: 1
        auth_host: KEYSTONE_URL
        username: RACKSPACE_USERNAME
        api_key: RACKSPACE_API_KEY

The top-level keys are connection names (if no argument is provided to
C<queue_server>, "default" is assumed).  Their values are
configuration maps with the following keys:

=over 4

=item host

String.  Hostname on which the Zaqar broker resides.

=item wants_auth

Boolean (although note that since L<YAML> does not properly support
boolean literals like C<true> and C<false>, you should instead use a
value that Perl recognizes as true or false, like C<1> or C<0>).

If this is set to a true value, the plugin will use C<auth_host>,
C<username> and C<api_key> to perform authentication to the Rackspace
auth services (Keystone, probably).  Otherwise, C<auth_host>,
C<username> and C<api_key> will be ignored.

=item auth_host

String.  Keystone endpoint.

=item username

String.  Rackspace client username.

=item api_keu

String.  Rackspace API key.

=back

=head1 SEE ALSO

L<Weborama::Windtrap::QueueServer>, L<WebService::Zaqar>.

=cut
