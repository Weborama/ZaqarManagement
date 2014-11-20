use Dancer ':syntax';
use Plack::Builder;
use Dancer::Handler;
use Dancer::Request;

use lib 'lib';

setting appdir => '.';
local $ENV{DANCER_APPDIR} = '.';
setting confdir => '.';
setting envdir => './environments';
Dancer::Config->load;

load_app "ZaqarManagement";
setting apphandler => 'PSGI';
Dancer::App->set_running_app("ZaqarManagement");

my $app = sub {
    my $env = shift;
    Dancer::Handler->init_request_headers($env);
    my $req = Dancer::Request->new(env => $env);
    Dancer::Handler->handle_request($req);
};
 
builder {
    mount '/' => $app;
};
