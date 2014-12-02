# ZaqarManagement

ZaqarManagement is a Dancer app using the Perl module
WebService::Zaqar to provide a web interface for managing Zaqar
queues.

 +  Queue creation and deletion
 +  Simple queue stats
 +  Post messages
 +  Claim messages
 +  Works on a local or remote Zaqar instance
 +  Works on a Rackspace Cloud Queue instance, supports authentication

# Installation

    $ git clone https://github.com/Weborama/ZaqarManagement.git
    $ cd ZaqarManagement
    $ cpanm -v --installdeps .
    $ plackup -s Starman -p 5002 --env development bin/plack.psgi

The app can be visited on [your browser](http://localhost:5002).
