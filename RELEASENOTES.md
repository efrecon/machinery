# Release Notes


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
