package ZaqarManagement;

use strict;
use warnings;
use 5.010;
use Carp;
use autodie;
use utf8;

use Dancer qw/:syntax/;
use Dancer::Plugin::Zaqar;
use Dancer::Plugin::FlashNote;
use DateTime;
use Try::Tiny;
use Time::HiRes;
use DateTime::Format::ISO8601;
use DateTime::Format::Human::Duration;

our $VERSION = '0.001';

my $iso_dt_parser = DateTime::Format::ISO8601->new;
my $spanner = DateTime::Format::Human::Duration->new;

hook 'before_template_render' => sub {
    my $tokens = shift;
    my $menu = [
        { title => "Queues",
          path => '/queues' },
        { title => "Messages",
          path => '/messages' },
        ];
    if (my $active_menu_item = var("active_menu_item")) {
        foreach my $menuitem (@{$menu}) {
            if ($menuitem->{title} eq $active_menu_item) {
                $menuitem->{is_active} = 1;
            } else {
                $menuitem->{is_active} = 0;
            }
        }
    }
    $tokens->{menu} = $menu;
    $tokens->{zm_version} = $VERSION;
    if (my $title = var('title')) {
        $tokens->{title} = $title;
    }
};

get '/' => sub {
    # check app config, display node health
    my $healthy;
    my $time = Time::HiRes::time;
    my $dt = DateTime->now(time_zone => 'UTC');
    my $response = try {
        queue_server->do_request(sub { queue_server->check_node_health });
    } catch {
        $healthy = 0;
        return $_;
    };
    if ($response->status == 204) {
        # healthy
        $healthy = 1;
    } elsif ($response->status >= 500) {
        # unavailable
        $healthy = 0;
    } else {
        # ... no auth?
        $healthy = -1;
    }
    template 'health', {
        healthy => $healthy,
        response_status => $response->status,
        rtt => (Time::HiRes::time - $time),
        date => $dt->datetime,
        host => queue_server->base_url };
};

get '/queues' => sub {
    # list queues, simple queue stats
    var title => 'List of queues';
    my $now = DateTime->now(time_zone => 'UTC');
    my $response = try {
        queue_server->do_request(sub { queue_server->list_queues(limit => 20) });
    } catch {
        warning $_;
        return $_;
    };
    my $queues;
    my %links;
    if ($response->status == 200) {
        $queues = { map { $_->{name} => { name => $_->{name} } } @{$response->body->{queues}} };
        %links = map { $_->{rel} => $_ } @{$response->body->{links}};
        while (my $href = $links{'next'}->{href}) {
            $response = queue_server->do_request(sub { queue_server->list_queues(__url__ => $href) });
            last if $response->status != 200;
            $queues = { %{$queues}, map { $_->{name} => { name => $_->{name} } } @{$response->body->{queues}} };
            %links = map { $_->{rel} => $_ } @{$response->body->{links}};
        }
        # now we have all queues; for each queue, get the queue's stats
        foreach my $queue (values %{$queues}) {
            my $stats_response = queue_server->do_request(sub { queue_server->get_queue_stats(queue_name => $queue->{name}) });
            $queue->{free_messages} = $stats_response->body->{messages}{free};
            $queue->{claimed_messages} = $stats_response->body->{messages}{claimed};
            if ($stats_response->body->{messages}{total} != 0) {
                $queue->{oldest_message_hla} = $spanner->format_duration_between($now, $iso_dt_parser->parse_datetime($stats_response->body->{messages}{oldest}{created}),
                                                                                 past => '%s ago',
                                                                                 future => 'in %s',
                                                                                 no_time => 'just now');
                $queue->{newest_message_hla} = $spanner->format_duration_between($now, $iso_dt_parser->parse_datetime($stats_response->body->{messages}{newest}{created}),
                                                                                 past => '%s ago',
                                                                                 future => 'in %s',
                                                                                 no_time => 'just now');
            } else {
                $queue->{oldest_message_hla} = 'N/A';
                $queue->{newest_message_hla} = 'N/A';
            }
        }
    } else {
        flash(warning => sprintf(q{Could not build list of queues: '%s' -- Please check node health!},
                                 $response));        
        $queues = {};
    }
    template 'queues', {
        queues => [ values %{$queues} ],
    };
};

get '/queue/:queue_name' => sub {
    # detailed queue stats, delete queue
    my $now = DateTime->now(time_zone => 'UTC');
    my $queue_name = param('queue_name');
    my $response = try {
        queue_server->do_request(sub { queue_server->exists_queue(queue_name => $queue_name) });
    } catch {
        return $_;
    };
    if ($response->status == 204) {
        my $stats_response = queue_server->do_request(sub { queue_server->get_queue_stats(queue_name => $queue_name) });
        my $queue_stats = {
            free_messages => $stats_response->body->{messages}{free},
            claimed_messages => $stats_response->body->{messages}{claimed},
            total_messages => $stats_response->body->{messages}{total},
        };

        if ($stats_response->body->{messages}{total} != 0) {
            $queue_stats->{oldest_message_hla} = $spanner->format_duration_between($now, $iso_dt_parser->parse_datetime($stats_response->body->{messages}{oldest}{created}),
                                                                                   past => '%s ago',
                                                                                   future => 'in %s',
                                                                                   no_time => 'just now');
            $queue_stats->{newest_message_hla} = $spanner->format_duration_between($now, $iso_dt_parser->parse_datetime($stats_response->body->{messages}{newest}{created}),
                                                                                   past => '%s ago',
                                                                                   future => 'in %s',
                                                                                   no_time => 'just now');
        } else {
            $queue_stats->{oldest_message_hla} = 'N/A';
            $queue_stats->{newest_message_hla} = 'N/A';
        }

        var title => "Queue $queue_name";
        template 'queue', { queue_name => $queue_name,
                            queue_stats => $queue_stats };
    } else {
        template 'no_such_queue', { queue_name => $queue_name };
    }
};

get '/queues/create' => sub {
    # create a queue
    var title => 'Create a queue';
    template 'queues_create';
};

post '/queues/create' => sub {
    my $queue_name = param('queue_name');
    queue_server->do_request(sub { queue_server->create_queue(queue_name => $queue_name) });
    redirect uri_for('/queues');
};

post '/queue/:queue_name/delete' => sub {
    my $queue_name = param('queue_name');
    queue_server->do_request(sub { queue_server->delete_queue(queue_name => $queue_name) });
    redirect uri_for('/queues');
};

get '/messages' => sub {
    # emit a message on a queue, claim N messages on a queue, delete a
    # message on a queue, delete a claim, release a claim
    my $response = try {
        queue_server->do_request(sub { queue_server->list_queues(limit => 20) });
    } catch {
        return $_;
    };
    my $queues;
    my %links;

    var title => 'Messages';
    if ($response->status == 204) {
        return template 'no_queues';
    } elsif ($response->status == 200) {
        $queues = { map { $_->{name} => { name => $_->{name} } } @{$response->body->{queues}} };
        %links = map { $_->{rel} => $_ } @{$response->body->{links}};
        while (my $href = $links{'next'}->{href}) {
            $response = queue_server->do_request(sub { queue_server->list_queues(__url__ => $href) });
            last if $response->status != 200;
            $queues = { %{$queues}, map { $_->{name} => { name => $_->{name} } } @{$response->body->{queues}} };
            %links = map { $_->{rel} => $_ } @{$response->body->{links}};
        }
        # we have all queues now
        return template 'messages', { queues => [ values %$queues ] };
    } else {
        # not 204, not 200, run away!
        flash(warning => sprintf(q{Could not build list of queues: '%s' -- Please check node health!},
                                 $response));
        return template 'messages', { queues => [] };
    }
};

post '/messages/claim' => sub {
    my $queue_name = param('queue_name');
    my $claim_ttl = param('claim_ttl');
    my $claim_grace = param('claim_grace');
    my $claim_limit = param('claim_limit');
    try {
        my $response = queue_server->do_request(sub {
            queue_server->claim_messages(queue_name => $queue_name,
                                         limit => $claim_limit,
                                         payload => {
                                             ttl => 0+$claim_ttl,
                                             grace => 0+$claim_grace }) });
        if ($response->status == 204) {
            flash(warning => sprintf(q{Claim successfully posted to '%s' but no messages available},
                                     $queue_name));
        } else {
            my @messages = @{$response->body};
            my $claims = session('claims');
            my $claim_href = $response->header('Location');
            $claims->{$claim_href} = {
                queue => $queue_name,
                ttl => $claim_ttl,
                grace => $claim_grace,
                href => $claim_href,
                messages => { map { $_->{href} => $_ } @messages } };
            session('claims' => $claims);
            flash(success => sprintf(q{Claim successfully posted to '%s', claimed %d messages; claim location is '%s'},
                                     $queue_name, scalar(@{$response->body}), $response->header('Location')));
        }
    } catch {
        flash(error => sprintf(q{Claim could not be posted to '%s': %s},
                               $queue_name, $_));
    };
    redirect uri_for('/messages');
};

post '/message/create' => sub {
    my $queue_name = param('queue_name');
    my $message_ttl = param('message_ttl');
    my $message_body = param('message_body');
    $message_body = try {
        $message_body = from_json($message_body);
    } catch {
        flash(error => sprintf(q{Message body must be valid JSON string (was '%s')},
                               $message_body));
        return;
    };
    unless ($message_body) {
        return redirect uri_for('/messages');
    }
    try {
        queue_server->do_request(sub {
            queue_server->post_messages(queue_name => $queue_name,
                                        payload => [ { ttl => 0+$message_ttl,
                                                       body => $message_body } ])
                                 });
        flash(success => sprintf(q{Message successfully posted to '%s'},
                                 $queue_name));
    } catch {
        flash(error => sprintf(q{Message could not be posted to '%s': %s},
                               $queue_name, $_));
    };
    redirect uri_for('/messages');
};

post '/messages/claim/release' => sub {
    my $claim_href = param('claim_href');
    my $queue_name = param('claim_queue_name');
    try {
        queue_server->do_request(sub {
            queue_server->release_claim(__url__ => $claim_href) });
        my $claims = session('claims');
        delete $claims->{$claim_href};
        session('claims' => $claims);
        flash(success => sprintf(q{Claim on queue '%s' successfully released},
                                 $queue_name));
    } catch {
        flash(error => sprintf(q{Claim on queue '%s' could not be released: %s},
                               $queue_name, $_));
    };
    redirect uri_for('/messages');
};

post '/messages/delete' => sub {
    my $message_href = param('message_href');
    my $claim_href = param('claim_href');
    my $queue_name = param('claim_queue_name');
    try {
        queue_server->do_request(sub {
            queue_server->delete_message(__url__ => $message_href) });
        my $claims = session('claims');
        delete $claims->{$claim_href}->{$message_href};
        session('claims' => $claims);
        flash(success => sprintf(q{Message on queue '%s' successfully deleted},
                                 $queue_name));
    } catch {
        flash(error => sprintf(q{Message on queue '%s' could not be deleted: %s},
                               $queue_name, $_));
    };
    redirect uri_for('/messages');
};

true;
