# machinery

`machinery` is a command-line tool to operate on a whole cluster of [Docker
Machine] virtual or bare-metal machines. `machinery` uses a YAML definition of
the whole cluster to create machines, bring them up or down, remove them at will
and create (overlay) networks to be used across deployed containers. In short,
`machinery` is to `docker-machine` what `docker-compose` is to `docker`. In
addition, `machinery` provides [Docker Swarm] and [Swarm Mode], and [Docker
Compose] integration. It will automatically arrange for the created virtual
machines to join the swarm cluster, generate the token(s) as needed or even
manage the life-cycle of several compose projects to be run on the cluster.
`machinery` can automatically bring up specific project files onto machines that
it controls. `machinery` is able to substitute the value of local environment
variables in the compose project files before bringing the services up. Together
with conventions for the dynamic construction of network-related environment
variables, this provides for a simple mechanism for service discovery.

In short `machinery` provides you with an at-a-glance view of your whole
cluster, from all the (virtual) machines that build it up, to all the services
that should be run, and on which machine(s). `machinery` provides both a
command-line and a REST API for operating on your cluster from the central
controlling point that it constructs. This document provides a quick
introduction to the main features of `machinery`, read the
[documentation](docs/Reference.md) for a thorough description of all its
functionality.

  [Docker Machine]: https://docs.docker.com/machine/
  [Docker Swarm]: https://docs.docker.com/swarm/
  [Swarm Mode]: https://docs.docker.com/engine/swarm
  [Docker Compose]: https://docs.docker.com/compose/

## Quick Tour

`machinery` reads its default configuration from the file `cluster.yml` in the
local directory. [YAML](http://yaml.org/) definition files have a
straightforward syntax.  For example, the following content would define 3
machines using the `virtualbox` driver, one with more memory and ready to be
duplicated through using the YAML anchoring facilities, another one with more
disk than the defaults provided by `docker-machine` and the last one as the
master of the cluster.  The description also defines some labels that can be
used by `swarm` to schedule services on specific nodes and arrange for the
machine called `core` to have access to your home directory. Finally, it
arranges for the services pinpointed by a relative `compose` project file to
automatically be started up when `db` is brought up and created.

```yaml
version: '2'

machines:
    wk01: &worker
      driver: virtualbox
      memory: 2GiB
      labels:
        role: worker
    db:
      driver: virtualbox
      size: 40G
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
```

Given access to a cluster definition file such as the one described above, the
following command would create all the configured machines and arrange for a
swarm token to be created when first executed.

```shell
machinery up
```

And the following command would gently bring the machine called `db` down and
then destroy it.

```shell
machinery destroy db
```

If you had a YAML compose project description file called `myapp.yml` describing
the containers to run on your cluster, you could schedule it for execution by
calling:

```shell
machinery swarm myapp.yml
```

Do you want to try for yourself at once? Read the next section ant try the
example. You might want to download a "compiled"
[binary](https://github.com/efrecon/machinery/releases) to avoid having to solve
the few dependencies `machinery` has yourself. For a complete description, read
the [documentation](docs/Reference.md).

## Giving it a Quick Test

The directory `test` contains a test cluster with a single machine.  Try for
yourself by running the following command from the main directory of the
repository.

```shell
./machinery -cluster test/test.yml up
```

You should see an output similar to the following one on the terminal. Actually,
what *you* will see is a colourised output without timestamps. `machinery`
automatically segregates terminals from regular file descriptor and the
following was captured using a file redirection.

```
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
```

To check around, you could run the following command to check that the machine
`test-test` has really been created:

```shell
docker-machine ls
```

You could also jump into the created machine using the following command:

```shell
docker-machine ssh test-test
```

At the prompt, you can perhaps get a list of the docker containers that have
been started in the machine using the following command and verify that there
are two running containers: one swarm master container and one swarm agent.

```shell
docker ps
```

You can also check which images have been downloaded using the following
command.  That should list at least 3 images: one for `swarm`, one for `busybox`
(which is used to verify that `docker` runs properly at the end of the machine
creation process) and finally one for Alpine Linux, which is downloaded as part
of the test cluster definition file.

```shell
docker images
```

Finally, you can check that you can access your home directory at its usual
place, as it is automatically mounted as part of the test cluster definition.  A
final note: jumping into the machine was not a necessary process, you would have
been able to execute those commands directly from the host command prompt after
having run `$(docker-machine env test-test)`.  

Once done, return to the host prompt and run the following to clean everything
up:

```shell
./machinery -cluster test/test.yml destroy
```

## Notes

Support for [Swarm Mode] is work in progress and not yet released yet, so is
support for the creation of cluster-wide overlay networks that can be used for
communication between [Docker Stack]s across the cluster. In order to handle the
creation of both machines and networks the YAML format has been modified in the
development version. The default is to keep a list of machines under the root of
the YAML file. However, whenever a key called `version` is present, `machinery`
will expect a list of machines under the key `machines` and a possible list of
networks under the key `networks`.

  [Docker Stack]: https://docs.docker.com/engine/reference/commandline/stack/

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

```shell
apt-get install tcllib
```
