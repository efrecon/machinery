# machinery

`machinery` is a command-line tool to operate on a whole cluster of
[Docker Machine] virtual or bare-metal machines. `machinery` uses a YAML
definition of the whole cluster to create machines, bring them up or down,
remove them at will and create (overlay) networks to be used across deployed
containers. In short, `machinery` is to `docker-machine` what `docker-compose`
is to `docker`. In addition, `machinery` provides [Docker Swarm] and
[Swarm Mode], and [Docker Compose] integration. It will automatically arrange
for the created virtual machines to join the swarm cluster, generate the
token(s) as needed or even manage the life-cycle of several compose projects to
be run on the cluster. `machinery` can automatically bring up specific project
files onto machines that it controls. `machinery` is able to substitute the
value of local environment variables in the compose project files before
bringing the services up. Together with conventions for the dynamic
construction of network-related environment variables, this provides for a
simple mechanism for service discovery.

`machinery` has been thoroughly tested on Linux, but is also able to run on
Windows, in the shell of the Docker
[Toolbox](https://www.docker.com/products/docker-toolbox).

  [Docker Machine]: https://docs.docker.com/machine/
  [Docker Swarm]: https://docs.docker.com/swarm/
  [Swarm Mode]: https://docs.docker.com/engine/swarm
  [Docker Compose]: https://docs.docker.com/compose/

## Command-Line API

`machinery` takes a number of global options (dash-led) followed by a
command.  These commands can be followed by command-specific options
and patterns matching the names of one or several virtual machines, as
specified in the YAML cluster description.  Those patterns are
glob-style patterns, where `*` matches any number of characters, `?` a
single character and `[` and `]` can be used to specify ranges of
characters.  UNIX shells may be inclined to resolve these patterns for
you, so you might have to quote your arguments.

### Commands

#### up

The command `up` will bring up one or several machines, which names
matching patterns would follow on the command line.  If no machines
are specified, `machinery` will bring up all machines in the cluster.
Machines that do not exist yet will be created prior to being brought
up, and a swarm token for the cluster will be generated if necessary
during that process.  More details are available in the section on the
supported YAML format.  Note that instead of `up`, machinery also
supports the synonym `start`.

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

When using v2 of the file format, any network that has not been created but has
been declared as part of the YAML description will be created whenever a manager
machine is created or brought up.

#### halt

The command `halt` will bring down one or several machines, which name
matching patterns would follow on the command line.  If no machines
are specified, `machinery` will bring down all machines in the
cluster.  Note that instead of `halt`, machinery also supports the
synonym `stop`.  All directories that should be synchronised will be
copied back to the host before their respective machines are brought
down.

#### destroy

The command `destroy` will destroy entirely and irrevocably one or
several machines, which name matching patterns would follow on the
command line.  If no machines are specified, `machinery` will destroy
all machines in the cluster.  Synchronised directories will be copied
before machine destruction.

#### sync

The command `sync` will recursively copy the content of VM directories
that are marked as shared back to the host.  Calling `machinery sync`
from a `cron` job is a good way to ensure data is copied between
restarts of the machines.

#### swarm

The command `swarm` will either schedule services to be run in the cluster or
print out its current status.  When called without arguments, `swarm` will print
out current cluster status i.e. the virtual machines that are registered within
the master and their details.

Arguments to `swarm` should be one or several path to YAML files.  `machinery`
recognises automatically two kinds of YAML files:

* Compose projects files will be substituted for environment variables and sent
  to the master of the cluster.  You will have to use labels or other scheduling
  techniques if you want to pinpoint specific machines where to run these
  services.

* `machinery` also recognises list of indirections to compose project files.
  These have exactly the same syntax as the [`compose` keys](#compose) of the
  regular YAML syntax.

`swarm` also takes a number of options that should appear before its arguments.
These specify what `docker-compose` operations will be executed on the specified
files.  You can specify several options in a row, for example to restart
services.  The supported options are:

* `-stop` matches the [`stop`](http://docs.docker.com/compose/cli/#stop) command
  of `compose` and will stop the services.

* `-kill` matches the [`kill`](http://docs.docker.com/compose/cli/#kill) command
  of `compose` and will kill the services.

* `-rm` matches the [`rm`](http://docs.docker.com/compose/cli/#rm) command
  of `compose` and will remove the services without asking at the prompt.

* `-start` matches the [`start`](http://docs.docker.com/compose/cli/#start)
  command of `compose` and will start stopped services.

* `-up` is the default when nothing is specified.  It matches the
  [`up`](http://docs.docker.com/compose/cli/#up) command of `compose` and
  will create and start the services in the background.  Additional option
  can be provided through the YAML syntax of indirecting files.

* `-options` is a way to pass instructions to `machinery` when parsing regular
  compose YAML project files, as if these files had been pointed at by the
  indirection   YAML format. The argument to `-options` should be a
  `,`-separated string where each token should take the form of `k=v` and
  where `k` is the name of a YAML indirection directive, such as
  `substitution` or `project` and where `v` is the overriding value. 

#### stack

The command `stack` only works with the new [Swarm Mode]. The command will pick
one of the existing running managers and deploy or operate further on stacks.
After the commands comes one of the sub-commands that are otherwise accepted by
`docker stack`. When the path to a compose file format is provided (through the
`-c` option for example), it is understood as relative to the current machinery
YAML file. All files that are pointed at by the compose file will automatically
be transferred to the remote manager so that the manager is able to find these
files at deployment time. In addition, deployment is able to understand
old-style v2 `extends` directives even as part of the v3 file format. Even
though this is not compatible, this departure provides with the flexibility that
has been requested by many.


#### node

The command `node` only works with the new [Swarm Mode]. The command will pick
one of the existing running managers and operate further on nodes as seen by the
manager. After the commands comes one of the sub-commands that are otherwise
accepted by `docker node` and the command and all its arguments are sent further
to the manager that had been randomly selected.


#### token

The command `token` will (re)generate a [Docker Swarm] token for cluster.
Cluster tokens are cached in hidden files in the same directory as the YAML file
that was used to describe the cluster. These files will have the same root name
as the cluster YAML file, but with a leading `.` to hide them and the extension
`.tkn`. `machinery token` will print out the token on the standard output, which
eases further automation. If a token for the cluster can be found in the cache,
it will be returned directly. To force regeneration of the token, you can
specify the option `-force` to the command.

Whenever a token needs to be generated, `machinery` will run `swarm create` in a
service on the local machine.  The service is automatically removed once the
token has been generated.  However, the image that might have been downloaded
will remain on the local machine.

#### env <a name="env" />

The command `env` will output all necessary bash commands to declare the
environment variables for network discovery.  In other words, running `eval
$(machinery env)` at the shell should set up a number of environment variables
starting with the prefix `MACHINERY_` and describing the network details of all
existing machines in the cluster.

#### ssh

The command `ssh` will execute a command within a virtual machine of
the cluster and print out its result on the standard output.  The
machine needs to be started for the command to succeed.  When run with
no additional arguments, an interactive command-line prompt will be
provided.

#### ps

When called without any argument, the command `ps` will ask the swarm
master to return the list of all running services, as of
`docker-machine ps`.  When called with arguments, these should be name
matching patterns and the command will return the list of running
services for that/those machine(s) instead.  Note that calling `ps`
with no argument, is different from running `ps "*"`.  In the first
case, only the services scheduled via swarm are printed out.  In the
second case, all services currently running in the cluster are
printed out, including those that would be issued from compose files
attached specifically attached to machines.

#### version

Print out the current version of the program on the standard output
and exit.

#### ls

Print out a static and dynamic summary of all the machines that are
comprised in the cluster.

#### search

`search` will look into the cluster for containers matching one or
more name patterns.  The command takes an option called `-restrict`
which argument should be a comma-separated list of patterns matching
the names of the virtual machines in the cluster.  When `-restrict` is
not specified, `search` will search within all virtual machines; when
provided with a list, only the machines which name match any of the
glob-style pattern will be considered.

All the remaining arguments to `search` should be glob-style patterns,
and these will be matched against the container names.  `search` will
output a table of the matching containers, together with their full
docker identifier and the machines on which they are running.

`search` is different from `ps` as it does not relies on `swarm` when
searching for the containers.

#### forall

`forall` can be used to execute the same docker command on a number of
containers or a number of virtual machines.  The command takes an
option called `-restrict` which argument should be a comma-separated
list of patterns matching the names of the virtual machines in the
cluster.  When `-restrict` is not specified, `forall` will consider
all the virtual machines; when provided with a list, only the machines
which name match any of the glob-style pattern will be considered.

In the most usual case, `forall` should take at least two arguments.
The first is a glob-style pattern matching the name of the containers
on the (restricted set of) machines.  All remaining arguments are the
name of the docker commands, and arguments that will be blindly passed
to the docker command when it is run.  For example, the following
command would restart all the containers of the cluster (note the
quote around the `*` to avoid shell substitution before sending the
value to `machinery`):

    machinery forall "*" restart

In the other case, `forall` detects that the first argument is the
name of an existing docker command and will then not run the command
on matching containers, which allows to run commands that do not
require a container name or identifier, such as `docker pull` for
example.  For example, the following would download the Alpine Linux
container onto all the machines in your cluster:

    machinery forall pull alpine

In case you had containers which name could match the name of a docker
command, it is possible to segregate the pattern matching the
container name from the command by inserting a double-dash in between.
So the example below would again restart all the containers, but
separation between the pattern and the command is now explicit:

    machinery forall "*" -- restart

#### server

### Interaction with system containers

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
virtual machines which names uses the rootname (sans the directory path) of the
cluster definition file as a prefix.  Supposed you had started `machinery` with
a YAML file called `mycluster.yml` and that it contained the definition for a
machine called `db`, running `machinery -cluster mycluster.yml create db` would
lead to the creation of a virtual machine called `mycluster-db`. Note that since
the context is fully specified, you could mention a reference to that machine
with the name `db` at the command-line.  However, calling `docker-machine ls`
will show up its real name, i.e. `mycluster-db`.  This behaviour will help you
managing several clusters from the same directory, for example when staging or
when running sub-sets of your architecture for development.

Note, that when neither a specifiy YAML file is pointed at using
`-cluster`, nor a default file called `cluster.yml` is found in the
current directory, `machinery` will try to find a good candidate YAML
description file automatically.  It will list all files ending with
`.yml` in the current directory and will consider those which first
empty line contains the marker `#docker-machinery`.  Whenever, only
one candidate is found, this file will be taken into consideration as
if it had been specifically pointed at using the `-cluster` global
option.

`docker-machine` itself stores a number of files that are necessary for
bootstrapping machines or for storing keys and certificates that are relevant
for the cluster. To keep this storage separate, but also to ease project
migration between machines, `machinery` creates a hidden directory using the
same basename as the YAML definition file, but with a leading dash and an ending
`.mch` extension in the same directory as the YAML definition file. Note that
versions prior to 0.7 did have a way to specify this directory, meaning that
they used the default directory `.docker` in your home directory. You can use
the global option `-storage` to interact with projects created using those
versions.

#### Interaction with `docker-compose` <a name="docker-compose" />

The combination of `machinery`, `docker-machine` and `docker-compose` enables a
single control point for an entire cluster.  This eases service discovery as it
makes possible to pass information between containers and machines of the
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

`machinery` supports a number of extra features when creating
virtualbox-based machines.  This requires proper access to the
`VBoxManage` command on the host machine.  These features are port
forwarding and the ability to mount host path into the guest machines.
The mounting of shares is made persistent as through modifying the
`bootlocal.sh` script of the `boot2docker` underlying image. However,
mounting operations are performed the first time the virtual machines
are started.  Technically, the implementation generates unique names
for the shares and declare those using `VBoxManage sharedfolder add`
the first time they are needed.  Then, each time the machine is
started, a mount operation will be performed using an `docker-machine
ssh`.

In practice, mounting of shares should be transparent to you,
independantly to how you start the machine: using the `start`
sub-command of `machinery`, starting manually using `docker-machine
start`).

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

This options takes the path to a YAML definition for your cluster.
The directory specified using this option will be the directory where
the cache for the swarm token is searched for and stored in.  It
defaults to the file `cluster.yml` in the current directory, when
present, or the only file ending with `.yml` and containing
`#docker-machinery` as its first non-empty line.

#### `-driver`

This option takes the name of a `docker-machine` driver as an
argument.  This is the driver that will be used when machines in the
YAML definition do not have any specific driver, but also to generate
the token, whenever this is relevant.

#### `-cache`

This option takes the name of a machine known to docker machine as an argument
and will conduct the behaviour of `machinery` when it installs images on the
machines that it creates.

When the cache is an empty string, `machinery` will use the local daemon to
fetch the image and create a `tar` of the image locally, before the `tar` file
is installed as a docker image on the remote machine. This has the advantage of
cutting down download times in some situations, but also to arrange for login
credentials to private registries not being present on the machines. Instead,
only local access to the images on the host is necessary.

When `-cache` is the name of a machine known to `docker-machine`, this machine
is used as a cache for image downloading. This behaviour is necessary on Windows
using the [Toolbox](https://www.docker.com/products/docker-toolbox) as there is
no local daemon, but rather a daemon running in a virtual machine.

To turn caching completely off, set this option to the `-`. When the
cache is turned off, `machinery` will ask the docker daemon running on the
remote machine to pull the images. This means that you will have to ensure that
proper credentials have been specified in the YAML file using the `registries`
section.

#### `-ssh`

When this option is set to an empty string, `machinery` will try to
introspect the raw `ssh` command to log into the machine from the
debug output of `docker-machine ssh`.  This will in turn be used as a
parameter to `rsync` (whenever relevant) or when copying files with
`scp` (when docker-machine does not support the `scp` sub-command).

When this option is set to a string, this should contain the complete
command to log into virtual machines using `ssh`.  As a cluster
contains more than one machine, the command can contain a number of
`%`-framed keys that will be dynamically be replaced with virtual
machine details whenever the ssh command is necessary.  These keys
are:

* `%user%` will contain the username into the machine, i.e. usually
  `docker`.
* `%host%` will contain the hostname of the machine (or its IP
  address).
* `%identity%` will contain the path to the RSA identity file for SSH
  security handshaking.  This file is usually generated by
  `docker-machine` when the machine is created.
* `%port%` will contain the port number on the machine for SSH access,
  it does not need to be `22`.

`machinery` is able to accomodate both `-l username` and
`username@host` constructs within the ssh command that is specified as
an argument to the `-ssh` option.  The second construct will
automatically be translated to the first (i.e. using the `-l` option
to `ssh` whenever necessary).  When it needs to construct `scp`
commands, `machinery` is able to convert between the option-space of
`ssh` and the one of `scp`, as these programs do not exactly take the
same options.

#### `-config`

This option takes the path to a file as an argument. When present, the
file will be read and its content will be used to initialised the
value of the options that can otherwise be specified as part of the
command-line global options.  However, command-line options, if
present, will always have precedence over the content of the file.  In
the file, any empty line will be ignored, any line starting with a `#`
will be considered as a comment and ignored.  Meaningful lines should
contain the name of a global option (the leading dash can be omitted)
followed by its value, separated by whitespaces.  The value can be put
between quotes `"` if necessary.

#### `-storage`

This option is the directory where `docker-machine` should store all necessary
files relevant for the cluster: bootstrapping OS images, certificates and keys,
etc. When empty, `machinery` will default to a directory that has the same
basename as the main YAML definition file, but starts with a `.` to be kept
hidden and ends with a `.mch`. `machinery` will automatically create that
directory and pass it further to `docker-machine` each time this is needed. This
option was introduced in version 0.7, to run `machinery` on clusters that were
created using prior versions, you will have to point out the default
`docker-machine` location, i.e. usually under `.docker/machine` in your home
directory.

## YAML Specification

Clusters are described using a YAML definition file. There are two versions of
this file format. When no version is specified, the old v1 is assumed and
`machinery` will default to [Docker Swarm]. When a toplevel key called version
exists and contains a version number greater than `2`, the file is considered to
be in the new file format and `machinery` will default to creating new
[Swarm Mode] clusters.

In the new file format, a toplevel key called `machines` should contain a list
of YAML dictionaries, where each key should be the name of a virtual machine
within that cluster. In the old file format, virtual machine names are toplevel
keys instead. Note that, as described before, `machinery` will prepend
the rootname of the YAML file to the virtual machine in `docker-machine` in most
cases. For each VM-specifying dictionary, `machinery` recognises a number of
keys as described below:

### `machines`

The machines top-level key, introduced in v2 contains a list of machines. In v1,
these names are at the top-level of the YAML hierarchy instead. Machines with a
name starting with a `.` (dot) or `x-` will be automatically ignored. Hidden
machines can be useful when combined with YAML anchors or the `extends` and
`include` directives. The following keys are allowed in machine descriptions:

#### `driver`

The value of `driver` should be the `docker-machine` driver to be used
when creating the machine.  If none is provided, the driver that is
specified at the command-line under the option `-driver` will be used.
This defaults to `virtualbox` as it is available on all platforms.

#### `master`

`master` should be a boolean and the value of `master` will specify if this
machine is (one of) the swarm master. In the old [Docker Swarm] there can only
be one swarm master per cluster, in the new [Swarm Mode], there can be several
masters. `machinery` will arrange for masters (and workers) to automatically
join the cluster as necessary.

#### `cpu`

`cpu` should be an integer and specifies the number of CPUs to allocate to that
virtual machine.  This will be automatically translated to each driver-specific
option whenever possible.  A warning will be issued at creation time if the
driver does not support that option.

#### `size`

In its simplest form, `size` is an integer and specifies the size of
the virtual disk for the virtual machine.  This should be expressed in
MB (see below).

To make it simpler, human-readable strings are also understood,
e.g. 20G would specify a size of 20 gigabytes.  `machinery` is able to
make the difference between units expressed using the International
System of Units (SI) and the binary-based units from the International
Electrotechnical Commission (IEC).  Thus `1GB` is written according to
SI metrics and is 1 000 000 000 bytes, while `1GiB` is written
according to IEC metrics and is 1 073 741 824 bytes.  Unit specifications
are case insensitive.

The option will be automatically translated to each driver-specific
option whenever possible, possibly making the translation between MB
and GB, or similar.  A warning will be issued at creation time if the
driver does not support that option.

#### `memory`

`memory` should specify the amount of memory for that virtual machine,
it defaults to being expressed in MiB (see discussion above).  This
will be automatically translated to each driver-specific option
whenever possible.  A warning will be issued at creation time if the
driver does not support that option.

#### `labels`

`labels` should be itself a dictionary.  The content of this dictionary will be
used as labels for the docker machines that are created.  These labels can be
used to schedule services on particular machines at a later time.

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

#### `extends`

`extends` should point to the name of another machine to extend the definition
of the current machine from. Current keys are recursively merged on top of the
keys from the machine pointed at with `extends`. `extends` can be recursive, but
at most `10` levels of resolutions will be performed. Using `extends` can be
handy in collaboration with hidden machines and `include`, as an alternative to
YAML anchors.

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
initiate containers.  Relative path are resolved to the directory
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
it schedules containers as image downloading takes too long.

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
all project files are brought up with the option `-d` to start their containers
in the background.

Another optional key called `substitution` can be set to a boolean.  When
`true`, the YAML compose file will be substituted for local environment
variables before being parsed by `docker-compose`.  See [above](#docker-compose)
for more information. Note that modern `docker-compose` will alway substitute
for you.

Two keys called `env_file` and `environment` can be used to point at environment
variables to be set when composing. `environment` has precedence over the
content of `env_file` and files pointed at `env_files` are read in their order.
The content of `environment` can either be a dictionary, or a list of `var=val`
mimicking the behaviour of regular compose files.

Finally a key called `project` can be set and is a string.  It will contain the
name of the compose project and will replace the one that usually is extracted
from the directory name.

#### `addendum`

`addendum` should be a list of dictionary that will, each, reference a
program or script to be run once a machine has been completely
initialised.

These dictionaries should at least contain a key called `exec`, which
content points to the program or script to run.  A relative path will
be understood as relative to the directory containing the YAML
description file for the cluster.

Additionally, the content of the optional key `args` will be given as
arguments when starting the program.  Finally, if a key called
`substitution` is present and set to a positive boolean, substitution
will occur in the run script, as for compose files above.

#### `prelude`

`prelude` should be a list of dictionary that will, each, reference a program or
script to be run as soon as a machine has been initiated. The prelude is
executed as soon as all files specified using the `files` directive have been
copied to the remote machine. This allows transfer of configuration files of all
sorts onto the host before its further initialisation. It works otherwise
similarly to `adddendum`.

#### `swarm`

By default, all machines specified in a YAML definition file will be part of the
same swarm cluster. You can turn this feature off by explicitely setting the key
`swarm` to a negative boolean.

#### `files`

specifies a list of files and directory copy specifications between the host and
the machine. There are two ways of describing file copies.

* In its easiest form, each specification is written as the source path (on the
  host) separated from the destination path (on the machine) using the `:`
  character. There can also follow a number of hints placed behind a trailing
  `:`. These hints are separated from one another using a coma sign, but the
  only recognised hint is currently `norecurse` which avoidss recusrion when
  directories are being copied.
  
* In its more complex form, each specification is a dictionary itself. This
  dictionary can contain the following keys:
  
  - `source` should point to the source file (or directory) and should always be
    present.
    
  - `destination` should point to the destination file (or directory) at the
    host and should always be present.
    
  - `sudo` is a boolean that, when on, will arrange for the file or directory to
    be copied to a temporary location before it is moved in place, at the host,
    using elevated privileges. This is to allow copying to sensitive parts of
    the filesystem.
    
  - `recurse` can be `auto` or a boolean. When `auto` is used, directories will
    be recursively coped automatically. Otherwise, the recursion will happen as
    specified by the boolean.
    
  - `delta` is a boolean that turns off delta-intelligent copying via `rsync` when
    the tool is picked up for copy by `docker-machine`. 

  - `mode` arranges for the mode of the file/directory at the host to be
    modified using `chmod`. This is mostly used together with `sudo`. 

  - `owner` arranges for the owner of the file/directory at the host to be
    modified using `chown`. This is mostly used together with `sudo`. 

  - `group` arranges for the group of the file/directory at the host to be
    modified using `chgrp`. This is mostly used together with `sudo`. 

Copies are issued using the underlying `scp` command of `docker-machine`. This
is still an experimental feature, but it eases migration of project relevant
files to relevant machines on the cluster. This can even include secrets as
transfers occurr under secured conditions.

### `include`

`include` can contain a list of files to import into the current YAML
description. Inclusion happens early on during parsing, and included files might
include other files themselves. `include` is usually used together with hidden
machines, i.e. with a name starting with a `.` or `x-`, and the `extends` key in
machine descriptions.
