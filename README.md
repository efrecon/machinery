# machinery

`machinery` is a command-line tool to operate on a whole cluster of [Docker
Machine](https://docs.docker.com/machine/) virtual machines. `machinery` uses a
YAML definition of the whole cluster to create machines, bring them up or down,
or remove them at will. In short, `machinery` is to `docker-machine` what
`docker-compose` is to 'docker'. `machinery` also provides [Docker
Swarm](https://docs.docker.com/swarm/) integration and will automatically
arrange for the created virtual machines to join the swarm cluster or generate
the token as needed.


## Quick Tour

`machinery` reads its default configuration from the file `cluster.yml` in the
local directory. YAML definition files have a straightforward syntax.  For
example, the following content would define three machines using the
`virtualbox` driver, one with more memory, the other one with more disk than the
defaults provided by `docker-machine` and the last one as the master of the
cluster. The description also defines some labels that can be used by `swarm` to
schedule components on specific nodes and arrange for the machine called `core`
to have access to your home directory.

    db:
      driver: virtualbox
      size: 20000
      labels:
        role: db
    wk01:
      driver: virtualbox
      memory:2048
      labels:
        role: worker
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

`machinery` is able to mount local host shares within the virtual machines that
runs the virtualbox driver.  Mounting is performed at each machine start,
meaning that from that point of view running `machinery up` with an existing
machine as an argument is not equivalent to running `docker-machine start` with
the same machine as an argument.

#### halt

The command `halt` will bring down one or several machines, which names would
follow on the command line.  If no machines are specified, `machinery` will
bring down all machines in the cluster.  Note that instead of `halt`, machinery
also supports the synonym `stop`.

#### destroy

The command `destroy` will destroy entirely and irrevocably one or several
machines, which names would follow on the command line.  If no machines are
specified, `machinery` will destroy all machines in the cluster.

#### swarm

The command `swarm` will contact the swarm master in the cluster and print out
its current status, i.e. the virtual machines that are registered within the
master and their details.

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

#### ssh

The command `ssh` will execute a command within a virtual machine of the cluster
and print out its result on the standard output.  The machine needs to be
started for the command to succeed.

#### version

Print out the current version of the program on the standard output and exit.

### Interaction with system components

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
a YAML file called mycluster.yml and that it contained the definition for a
machine called `db`, running `machinery -cluster mycluster.yml create db` would
lead to the creation of a virtual machine called `mycluster-db`. Note that since
the context is fully specified, you could mention a reference to that machine
with the name `db` at the command-line.  However, calling `docker-machine ls`
will show up its real name, i.e. `mycluster-db`.  This behaviour will help you
managing several clusters from the same directory, for example when staging or
when running sub-sets of your architecture for development.

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

`shares` should be a list of share mounting specifications.  A specification is
a either a single path or a host path separated from a guest path using a colon.
When there is a single path, this path will be used as both the host and the
guest path.  In paths, any occurrence of the name of an environment variable
preceded with the `$`-sign will be replaced by the value of that local variable.

At present, share mounting is only supported on virtualbox based machines.
Shares are declared once within the virtual machine, but they will be mounted as
soon as a machine has been brought up using a `mount` command executed in the
guest machine at startup.

## Comparison to Other Tools

`machinery` is closely related to [Vagrant](https://www.vagrantup.com/), and it
evens provides a similar set of commands.  However, being built on top of
`docker-machine` provides access to many more providers through all the existing
Docker Machine [drivers](https://docs.docker.com/machine/#drivers).

## Implementation

`machinery` is written in [Tcl](http://www.tcl.tk/). It requires a recent
version of Tcl (8.5 at least) and the `yaml` library to be able to parse YAML
description files.  As the `yaml` library is part of the standard `tcllib`, the
easiest is usually to install the whole library using your package manager.  For
example, on ubuntu, running the following will suffice as Tcl is part of the
core server and desktop installation.

    apt-get install tcllib
