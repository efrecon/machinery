# machinery

`machinery` is a command-line tool to operate on a whole cluster of [Docker
Machine](https://docs.docker.com/machine/) virtual machines. `machinery` uses a
YAML definition of the whole cluster to create machines, bring them up or down,
or remove them at will. In short, `machinery` is to `docker-machine` what
`docker-compose` is to `docker`. In addition, `machinery` provides [Docker
Swarm](https://docs.docker.com/swarm/) and
[Compose](https://docs.docker.com/compose/) integration. It will automatically
arrange for the created virtual machines to join the swarm cluster, generate the
token as needed or even manage the life-cycle of several compose projects to be
run on the cluster. `machinery` can automatically bring up specific project
files onto machines that it controls. `machinery` is able to substitute the
value of local environment variables in the compose project files before
bringing the components up.  Together with conventions for the dynamic
construction of network-related environment variables, this provides for a
simple mechanism for service discovery.

In short `machinery` provides you with an at-a-glance view of your whole
cluster, from all the (virtual) machines that build it up, to all the components
that should be run, and on which machine(s).

## Quick Tour

`machinery` reads its default configuration from the file `cluster.yml` in the
local directory. [YAML](http://yaml.org/) definition files have a
straightforward syntax.  For example, the following content would define 3
machines using the `virtualbox` driver, one with more memory and ready to be
duplicated through using the YAML anchoring facilities, another one with more
disk than the defaults provided by `docker-machine` and the last one as the
master of the cluster. The description also defines some labels that can be used
by `swarm` to schedule components on specific nodes and arrange for the machine
called `core` to have access to your home directory. Finally, it arranges for
the components pinpointed by a relative `compose` project file to automatically
be started up when `db` is brought up and created.

    wk01: &worker
      driver: virtualbox
      memory:2048
      labels:
        role: worker
    db:
      driver: virtualbox
      size: 20000
      labels:
        role: db
      compose:
        -
          file: ../compose/backend/db.yml
    core:
      driver: virtualbox
      master: on
      labels:
        role: core
      shares:
        - $HOME

Given access to a cluster definition file such as the one described above, the
following command would create all the configured machines and arrange for a
swarm token to be created when first executed.

    machinery up

And the following command would gently bring the machine called `db` down and
then destroy it.

    machinery destroy db

If you had a YAML compose project description file called `myapp.yml` describing
the components to run on your cluster, you could schedule it for execution by
calling:

    machinery swarm myapp.yml

Do you want to try for yourself at once? Jump to the bottom of this
documentation and read and try the example section.  You might want to
download a "compiled" [binary](https://github.com/efrecon/machinery/releases)
to avoid solving dependencies.

## Operating on the cluster

`machinery` takes a number of global options (dash-led) followed by a command.
These commands can be followed by command-specific options and the names of one
or several virtual machines, as specified in the YAML cluster description.

### Commands

#### up

The command `up` will bring up one or several machines, which names would follow
on the command line.  If no machines are specified, `machinery` will bring up
all machines in the cluster.  Machines that do not exist yet will be created
prior to being brought up, and a swarm token for the cluster will be generated
if necessary during that process.  More details are available in the section on
the supported YAML format.  Note that instead of `up`, machinery also supports
the synonym `start`.

`machinery` is able to mount local host shares within the virtual
machines that runs the virtualbox driver.  Mounting is made persistent
so that future runs of `docker-machine start` with the same machine as
an argument will properly mount the shares.  On all other drivers,
`machinery` will use rsync when bringing up and down the machines to
keep the directories synchronised.

In addition, `machinery` keeps a hidden environment file with the
networking information for all the machines of the cluster ([see
below](#netinfo)).  This file will have the same root name as the
cluster YAML file, but with a leading `.` to hide it and the extension
`.env` (see `env` [command description](#env)).

#### halt

The command `halt` will bring down one or several machines, which
names would follow on the command line.  If no machines are specified,
`machinery` will bring down all machines in the cluster.  Note that
instead of `halt`, machinery also supports the synonym `stop`.  All
directories that should be synchronised will be copied back to the
host before their respective machines are brought down.

#### destroy

The command `destroy` will destroy entirely and irrevocably one or
several machines, which names would follow on the command line.  If no
machines are specified, `machinery` will destroy all machines in the
cluster.  Synchronised directories will be copied before machine
destruction.

#### sync

The command `sync` will recursively copy the content of VM directories
that are marked as shared back to the host.  Calling `machinery sync`
from a `cron` job is a good way to ensure data is copied between
restarts of the machines.

#### swarm

The command `swarm` will either schedule components to be run in the cluster or
print out its current status.  When called without arguments, `swarm` will print
out current cluster status i.e. the virtual machines that are registered within
the master and their details.

Arguments to `swarm` should be one or several path to YAML files.  `machinery`
recognises automatically two kinds of YAML files:

* Compose projects files will be substituted for environment variables and sent
  to the master of the cluster.  You will have to use labels or other scheduling
  techniques if you want to pinpoint specific machines where to run these
  components.

* `machinery` also recognises list of indirections to compose project files.
  These have exactly the same syntax as the [`compose` keys](#compose) of the
  regular YAML syntax.

`swarm` also takes a number of options that should appear before its arguments.
These specify what `docker-compose` operations will be executed on the specified
files.  You can specify several options in a row, for example to restart
components.  The supported options are:

* `-stop` matches the [`stop`](http://docs.docker.com/compose/cli/#stop) command
  of `compose` and will stop the components.

* `-kill` matches the [`kill`](http://docs.docker.com/compose/cli/#kill) command
  of `compose` and will kill the components.

* `-rm` matches the [`rm`](http://docs.docker.com/compose/cli/#rm) command
  of `compose` and will remove the components without asking at the prompt.

* `-start` matches the [`start`](http://docs.docker.com/compose/cli/#start) command
  of `compose` and will start stopped components.

* `-up` is the default when nothing is specified.  It matches the
  [`up`](http://docs.docker.com/compose/cli/#up) command of `compose` and
  will create and start the components in the background.  Additional option
  can be provided through the YAML syntax of indirecting files.

* `-options` is a way to pass instructions to `machinery` when parsing regular
  compose YAML project files, as if these files had been pointed at by the
  indirection   YAML format. The argument to `-options` should be a
  `,`-separated string where each token should take the form of `k=v` and
  where `k` is the name of a YAML indirection directive, such as
  `substitution` or `project` and where `v` is the overriding value. 

#### token

The command `token` will (re)generate a swarm token for cluster.  Cluster tokens
are cached in hidden files in the same directory as the YAML file that was used
to describe the cluster.  These files will have the same root name as the
cluster YAML file, but with a leading `.` to hide them and the extension `.tkn`.
`machinery token` will print out the token on the standard output, which eases
further automation.  If a token for the cluster can be found in the cache, it
will be returned directly.  To force regeneration of the token, you can specify
the option `-force` to the command.

Whenever a token needs to be generated, `machinery` will run `swarm create` in a
component on the local machine.  The component is automatically removed once the
token has been generated.  However, the image that might have been downloaded
will remain on the local machine.

#### env <a name="env" />

The command `env` will output all necessary bash commands to declare the
environment variables for network discovery.  In other words, running `eval
$(machinery env)` at the shell should set up a number of environment variables
starting with the prefix `MACHINERY_` and describing the network details of all
existing machines in the cluster.

#### ssh

The command `ssh` will execute a command within a virtual machine of the cluster
and print out its result on the standard output.  The machine needs to be
started for the command to succeed.

#### version

Print out the current version of the program on the standard output and exit.

### Interaction with system components

#### Networking Information <a name="netinfo" />

`machinery` keeps a hidden environment file with the networking information for
all the machines of the cluster.  This file will have the same root name as the
cluster YAML file, but with a leading `.` to hide it and the extension `.env`.
The file defines a number of environment variables.  Given the full name of a
machine, e.g. `mycluster-mymachine`, a whole uppercase prefix will be
constructed by prefixing `MACHINERY_` to the name of the machine in uppercase,
followed by another `_`.  So, the previous example  would lead to the prefix:
`MACHINERY_MYCLUSTER_MYMACHINE_` (note that the dash has been replaced by an
`_`).  This prefix will be prepend to the following strings:

* `IP`, the main IPv4 address of the virtual machine.

* And, for each relevant network interface name, e.g. `if`, at maximum two
  variables with the name of the interface in uppercase followed by a `_` will
  be constructed: one for the IPv4 address (suffix INET) and one for the IPv6
  address (suffix INET6), when they are present.

To wrap it up, and for the same machine name example as above, you might find
the following in the environment file:

    MACHINERY_MYCLUSTER_MYMACHINE_DOCKER0_INET=172.17.42.1
    MACHINERY_MYCLUSTER_MYMACHINE_DOCKER0_INET6=fe80::5484:7aff:fefe:9799/64
    MACHINERY_MYCLUSTER_MYMACHINE_ETH0_INET=10.0.2.15
    MACHINERY_MYCLUSTER_MYMACHINE_ETH0_INET6=fe80::a00:27ff:fec2:ea1/64
    MACHINERY_MYCLUSTER_MYMACHINE_ETH1_INET=192.168.99.111
    MACHINERY_MYCLUSTER_MYMACHINE_ETH1_INET6=fe80::a00:27ff:fe58:c217/64
    MACHINERY_MYCLUSTER_MYMACHINE_LO_INET=127.0.0.1
    MACHINERY_MYCLUSTER_MYMACHINE_LO_INET6=::1/128
    MACHINERY_MYCLUSTER_MYMACHINE_IP=192.168.99.111

#### Interaction with `docker-machine`

At a meta-level, `machinery` is simply a high-level interface to
`docker-machine`.  It will indeed call `docker-machine` for most of its under
operations, for example when creating machines, stopping them, starting them,
etc.  The power of `mcahinery` is that it is able to operate on the whole
cluster at one time, but also to provide a single summary point for all the
machines of a specific cluster through the YAML definition.

By default, `machinery` will look for a file called `cluster.yml` in the current
directory.  This mimics the operation of related commands such as
`docker-compose`.  However, `machinery` is able to take a specific cluster
definition file through its `-cluster` global option and its behaviour will
slightly change in that case.  Whenever started with the `-cluster` option
pointing at another file than the default `cluster.yml`, `machinery` will create
virtual machines which name uses the rootname (sans the directory path) of the
cluster definition file as a prefix.  Supposed you had started `machinery` with
a YAML file called `mycluster.yml` and that it contained the definition for a
machine called `db`, running `machinery -cluster mycluster.yml create db` would
lead to the creation of a virtual machine called `mycluster-db`. Note that since
the context is fully specified, you could mention a reference to that machine
with the name `db` at the command-line.  However, calling `docker-machine ls`
will show up its real name, i.e. `mycluster-db`.  This behaviour will help you
managing several clusters from the same directory, for example when staging or
when running sub-sets of your architecture for development.

#### Interaction with `docker-compose` <a name="docker-compose" />

The combination of `machinery`, `docker-machine` and `docker-compose` enables a
single control point for an entire cluster.  This eases service discovery as it
makes possible to pass information between components and machines of the
cluster.  `machinery` provides a solution to this through extending the YAML
format for `docker-compose`.  When substitution is turned on for a YAML compose
project file, any occurrence of a *local* environment variable will be replaced
by its value before being passed to `docker-compose`.  The syntax also provides
for default values, e.g. `${MYVAR:default}` will be replaced by the content of
the environment variable `MYVAR` if it existed, or by `default` if it did not
exist.  The implementation will perform local substitution into a temporary file
that will be passed to `docker-compose`.  In particular, all the environment
variables described [above](#netinfo) will be available for substitution prior
to `docker-compose`.

Authoring YAML files this way does not follow the official syntax, but you
should still be able to pass your files to `docker-compose` after having fed
them through
[envsubst](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html).

#### Interaction with `VBoxManage`

`machinery` supports a number of extra features when creating virtualbox-based
machines.  This requires proper access to the `VBoxManage` command on the host
machine.  These features are port forwarding and the ability to mount host path
into the guest machines.  The mounting of shares is not persistent as
`/etc/fstab` is read-only in boot2docker. Instead mounting operations will be
performed each time the virtual machines are started.  Technically, the
implementation generates unique names for the shares and declare those using
`VBoxManage sharedfolder add` the first time they are needed.  Then, each time
the machine is started, a mount operation will be performed using an
`docker-machine ssh`.

In practice, mounting of shares should be transparent to you as long as you
start machines that use this feature using `machinery` (as opposed to manually
using `docker-machine start`).

### Global Options

`machinery` takes a number of global options before the command that it should
execute.  These options will affect its behaviour and are detailed below.

#### `-help`

Print some help on the standard output and exit.  This is the same exact
behaviour as calling `machinery help`.

#### `-machine`

This option should take as a value the path to your locally installed
`docker-machine` binary.  It defaults to `docker-machine`, which will attempt to
find and run `docker-machine` using your `PATH`.

#### `-docker`

This option is similar to `docker-machine` and can be used to pinpoint a
specific `docker` binary to run.

#### `-token`

This option takes a swarm token string as an argument and will override the
token that would otherwise be generated and/or read from the (hidden) cache.

#### `-cluster`

This options takes the path to a YAML definition for your cluster.  The
directory specified using this option will be the directory where the cache for
the swarm token is searched for and stored in.  It defaults to the file
`cluster.yml` in the current directory.

#### `-driver`

This option takes the name of a `docker-machine` driver as an argument.  This is
the driver that will be used when machines in the YAML definition do not have
any specific driver, but also to generate the token.

### YAML Specification

Clusters are described using a YAML definition file.  These files should contain
a list of YAML dictionaries, where each key should be the name of a virtual
machine within that cluster.  Note that, as described before, `machinery` will
prepend the rootname of the YAML file to the virtual machine in `docker-machine`
in most cases. For each VM-specifying dictionary, `machinery` recognises a
number of keys as described below:

#### `driver`

The value of `driver` should be the `docker-machine` driver to be used when
creating the machine.  If none is provided, the driver that is specified at the
command-line under the option `-driver` will be used.  This defaults to
`virtualbox` as it is available on all platforms.

#### `master`

`master` should be a boolean and the value of `master` will specify if this
machine is the swarm master.  There can only be one swarm master per cluster.

#### `cpu`

`cpu` should be an integer and specifies the number of CPUs to allocate to that
virtual machine.  This will be automatically translated to each driver-specific
option whenever possible.  A warning will be issued at creation time if the
driver does not support that option.

#### `size`

`size` should be an integer and specifies the size of the virtual disk for the
virtual machine.  This should be expressed in MB.  The option will be
automatically translated to each driver-specific option whenever possible,
possibly making the translation between MB and GB, or similar.  A warning will
be issued at creation time if the driver does not support that option.  

#### `memory`

`memory` should be an integer and specifies the amount of memory in MB to
allocate for that virtual machine.  This will be automatically translated to
each driver-specific option whenever possible.  A warning will be issued at
creation time if the driver does not support that option.

#### `labels`

`labels` should be itself a dictionary.  The content of this dictionary will be
used as labels for the docker machines that are created.  These labels can be
used to schedule components on particular machines at a later time.

#### `options`

`options` should be itself a dictionary and contain a number of driver-specific
options that will be blindly passed to the driver at machine creation.  The
leading double-dash that precedes these options can be omitted to keep the
syntax simpler.

#### `ports`

`ports` should be a list of port forwarding specifications.  A specification is
either a single port or a host port separated from a guest port using a colon.
When there is a single port, this port will be used as both the host and the
guest port. It can also contain a trailing protocol specification following a
slash, that defaults to tcp.  So `8080:80` would forward the local host port
`8080` onto the guest port `80`.  And `20514:514/udp` would forward port `20514`
onto the standard syslog port `514` on UDP.

At present, port forwarding is only meaningful and supported on virtualbox based
machines.

#### `shares`

`shares` should be a list of share mounting specifications.  A
specification is a either a single path or a host path separated from
a guest path using a colon.  In addition, there might be a trailing
type following another colon sign.  Recognised types are `vboxsf` and
`rsync`.  When there is a single path (or the guest path is empty),
this path will be used as both the host and the guest path.  In paths,
any occurrence of the name of an environment variable preceded with
the `$`-sign will be replaced by the value of that local variable.
For example, specifying `$HOME` would arrange for the path to your
home directory to be available at the same location within the guest
machine; handy whenever you want to transfer development files or
initiate components.  Relative path are resolved to the directory
hosting the cluster definition YAML file.

The default type is `vboxsf` on virtualbox-based machines and `rsync`
on top of all other drivers.  When using the `rsync`type, you can
bring back changes that would have occured within the virtual machine
onto the host using the command `sync`.  When proper mounting is
possible, the mounting will persist restarts of the virtual machine,
e.g. when doing `docker-machine restart` or similar.

#### `images`

`images` should be a list of images to automatically pull from
registries once a virtual machine has been created, initialised and
verified.  This can be handy if you want to make sure images are
already present when your machine is being put into action.  For
example, `docker-compose` will sometimes timeout the first time that
it schedules components as image downloading takes too long.

The default behaviour is to download images on the host and to
transfer them to the virtual machine using a combination of `docker
save` and `docker load`, i.e. as `tar` files.  This has two benefits:

1. You can easily push images of private nature onto the virtual
   machines without exporting any credentials or similar.
2. If you have many machines using the same image, this can be quicker
   than downloading from a remote registry.

To switch off that behaviour and download the images from the virtual
machines instead, set the global option `-cache` to `off`, `0` or
`false`.

#### `registries`

`registries` should be a list of dictionaries specifying (private) registries at
which to login upon machine creation.  These dictionaries should contain values
for the following keys: `server`, `username`, `password` and `email`, where
server is the URL to the registry and the other fields are self-explanatory.
`machinery` will log into all specified registries before attempting to
pre-download images as explained above.

#### `compose` <a name="compose" />

`compose` should be a list of dictionaries that will, each, reference a
`docker-compose` project file.  Each dictionary must have a key called `file`
that contains the path to the compose project file.  A relative path will be
understood as relative to the directory containing the YAML description file,
thus allowing you to easily copy and/or transfer entire hierarchies of files.

Additionally, a key called `options` can be specified and it will contain a list
of additional options that will be passed to `docker-compose up`.  By default,
all project files are brought up with the option `-d` to start their components
in the background.

Another optional key called `substitution` can be set to a boolean.  When
`true`, the YAML compose file will be substituted for local environment
variables before being parsed by `docker-compose`.  See [above](#docker-compose)
for more information.

Finally a key called `project` can be set and is a string.  It will contain the
name of the compose project and will replace the one that usually is extracted
from the directory name.

## Giving it a quick test

The directory `test` contains a test cluster with a single machine.  Try for
yourself by running the following command from the main directory of the
repository.

    ./machinery -cluster test/test.yml up

You should see an output similar to the following one on the terminal.
Actually, what *you* will see is a colourised output without timestamps.
`machinery` automatically segregates terminals from regular file descriptor and
the following was captured using a file redirection.

    [20150414 204739] [NOTICE] Generating new token
    [20150414 204739] [INFO] Detaching from vm...
    [20150414 204739] [INFO] Creating swarm token...
    [20150414 204740] [NOTICE] Created cluster token 87c9e52eb6be5d0c794afa7053462667
    [20150414 204740] [INFO] Token for cluster definition at test/test.yml is 87c9e52eb6be5d0c794afa7053462667
    [20150414 204740] [NOTICE] Creating machine test-test
    [20150414 204741] [INFO]   Creating SSH key...
    [20150414 204741] [INFO]   Creating VirtualBox VM...
    [20150414 204743] [INFO]   Starting VirtualBox VM...
    [20150414 204743] [INFO]   Waiting for VM to start...
    [20150414 204829] [INFO]   Configuring Swarm...
    [20150414 204849] [INFO]   "test-test" has been created and is now the active machine.
    [20150414 204849] [INFO]   To point your Docker client at it, run this in your shell: $(docker-machine env test-test)
    [20150414 204849] [INFO] SSH to test-test working properly
    [20150414 204849] [NOTICE] Tagging test-test with role=testing target=dev
    [20150414 204849] [NOTICE] Copying local /tmp/profile-11494-395 to test-test:/tmp/profile-11494-395
    [20150414 204856] [INFO]   Waiting for VM to start...
    [20150414 204928] [NOTICE] Port forwarding for test-test as follows: 8080->80/tcp 20514->514/udp 9090->9090/tcp
    [20150414 204929] [NOTICE] Mounting shares as follows for test-test: /home/emmanuel->/home/emmanuel
    [20150414 204929] [INFO] Getting info for guest test-test
    [20150414 204929] [NOTICE] Waiting for test-test to shutdown...
    [20150414 204934] [NOTICE] Bringing up machine test-test...
    [20150414 204935] [INFO]   Waiting for VM to start...
    [20150414 205007] [INFO] Attaching to test-test
    [20150414 205012] [INFO] Docker setup properly on test-test
    [20150414 205012] [NOTICE] Pulling images in test-test: gliderlabs/alpine
    [20150414 205012] [INFO] Attaching to test-test
    [20150414 205013] [INFO]   Pulling repository gliderlabs/alpine
    [20150414 205015] [INFO]   a5b60fe97da5: Pulling image (latest) from gliderlabs/alpine
    [20150414 205015] [INFO]   a5b60fe97da5: Pulling image (latest) from gliderlabs/alpine, endpoint: https://registry-1.docker.io/v1/
    [20150414 205016] [INFO]   a5b60fe97da5: Pulling dependent layers
    [20150414 205016] [INFO]   511136ea3c5a: Download complete
    [20150414 205016] [INFO]   a5b60fe97da5: Pulling metadata
    [20150414 205017] [INFO]   a5b60fe97da5: Pulling fs layer
    [20150414 205019] [INFO]   a5b60fe97da5: Download complete
    [20150414 205019] [INFO]   a5b60fe97da5: Download complete
    [20150414 205019] [INFO]   Status: Downloaded newer image for gliderlabs/alpine:latest

To check around, you could run the following command to check that the machine
`test-test` has really been created:

    docker-machine ls

You could also jump into the created machine using the following command:

    docker-machine ssh test-test

At the prompt, you can perhaps get a list of the docker components that have
been started in the machine using the following command and verify that there
are two running components: one swarm master component and one swarm agent.

    docker ps

You can also check which images have been downloaded using the following
command.  That should list at least 3 images: one for `swarm`, one for `busybox`
(which is used to verify that `docker` runs properly at the end of the machine
creation process) and finally one for Alpine Linux, which is downloaded as part
of the test cluster definition file.

    docker images

Finally, you can check that you can access your home directory at its usual
place, as it is automatically mounted as part of the test cluster definition.  A
final note: jumping into the machine was not a necessary process, you would have
been able to execute thos commands directly from the host command prompt after
having run `$(docker-machine env test-test)`.  

Once done, return to the host prompt and run the following to clean everything
up:

    ./machinery -cluster test/test.yml destroy

## Comparison to Other Tools

`machinery` is closely related to [Vagrant](https://www.vagrantup.com/), and it
evens provides a similar set of commands.  However, being built on top of
`docker-machine` provides access to many more providers through all the existing
Docker Machine [drivers](https://docs.docker.com/machine/#drivers).

## Implementation

`machinery` is written in [Tcl](http://www.tcl.tk/). It requires a recent
version of Tcl (8.6 at least) and the `yaml` library to be able to parse YAML
description files.  As the `yaml` library is part of the standard `tcllib`, the
easiest is usually to install the whole library using your package manager.  For
example, on ubuntu, running the following will suffice as Tcl is part of the
core server and desktop installation.

    apt-get install tcllib
