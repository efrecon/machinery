# Release Notes

## v 0.5

* The default is now to use the locally cached images when
  initialising virtual machines.  This will speed up initialisation in
  a number of cases.  Furthermore, this allows to push private images
  on the machines withouth having to transfer repository credentials
  or similar.

* Factored away UNIX/linux specific commands into a separate package
  to keep down the size of the main code-base.


## v 0.4.2 (Never Released)

* Fixed a bug when swarming compose project files: these would be started up on
  the host and not within the cluster!

* Added possibility to pass project name or substitution instructions to YAML
  compose files being swarmed into the cluster.

* Fixed bug so that `.env` files pointed by project files that should be
  substituted will also be substituted and will be found by the project file
  when running compose.

* Fixed bug where compose projects would not be properly resolved when started
  using `swarm`.

* (Finally?) fixing login/pull bug so `machinery` will now be able to
  properly download from private repositories.

* Adding support for aliases, a new key called `aliases` under the VM
  dictionary in the YAML file.  This should be a list of names that
  can also be used to point at the machine from the command line, but
  will also appear in the discovery mechanisms.

* Squeezed away a number of synchronisation bugs that would occur on
  slow hosts, we typically wait for good markers and retry a number of
  times sensitive operations.
  

## v 0.4.1

* Added support for passing docker-compose commands when swarming in
  project files: -kill, -start, -rm, etc.

* Fixed output bug so we get (again!) a list of running components
  once compose operations have ended.


## v 0.4 (never released)

* Added support for substitution of (local) environment variables as a
  workaround for this
  [highly-requested](https://github.com/docker/compose/issues/495) missing
  feature of compose.  However, this means that, when crafting compose project
  files to use the feature, you will not be able to use them directly outside of
  `machinery`, unless you run them through
  [envsubst](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html)

* Adding support for "poor man's discovery".  `machinery` automatically declares
  and caches environment variables with network information for the created
  machines.  These variables can be, for example, used when starting components
  through compose (see above).

* Adding support for logging in at one or several registries at the `docker`
  daemon running within a specific virtual machine.  Note that you will have to
  start the components under the same user than the one that was automatically
  logged in.

* Adapting to new versions of `docker`, `docker-machine` and `docker-compose`.

* Automatically trying to update a machine to the latest   `boot2docker.iso`
  when the installed version of `docker` is lower than the one of the local
  installation.

* Arrange for the temporary files created for performing environment variable
  substitution to point back correctly to the source files when using extending
  services with compose.

* Adding an `env` command to export all machinery network details to shell.

* Extending the `swarm` command so it takes a list of compose project files, or
  indirections to compose project file in a format similar to the `compose` key
  of the YAML syntax.  These projects will be sent to the swarm master for
  creation.

* Adding a `reinit` command to trigger some of the machine initialisation steps,
  such as image downloading or component creation.


## v 0.3

* Added support for automatically run `docker-compose up` against a given
  machine.  This allows to bypass swarm (for development purposes), or to
  schedule components on globally.


## v 0.2.2

* Refactoring of the code to move out all swarm-related code to a separate
  (internal) package.

* Introduces two new (internal) commands to call `docker` and `docker-machine`
  so as to ensure standardised behaviour.  These also place both commands in
  debug mode whenever the current verbosity level is greater than DEBUG.

* Fixed mounting of shares so docker user inside the virtual box guest can also
  write to files.


## v 0.2.1

* Adding YAML syntax for automatically pull a number of repositories once a
  machine has been created and initiated.


## v 0.2

* Intelligent logging, will behave differently when logging to a
  terminal or to a regular file descriptor.

* Convert between logrus (and thus docker-machine) log levels and
  internal log levels for an improved output.

* Now creates cluster token using a local docker component, which
  reduces generation time as we do not require the creation of a
  temporary virtual machine.

* Support port forwarding and share mounting on top of the virtualbox
  driver.

* Adding support for application versioning (to make files like this
  one more meaninfull!).

* Renamed `machinery info` to `machinery swarm` to make it more explicit.


## v 0.1

First official version pushed out to github.  This provides a
reduced but working set of features.
