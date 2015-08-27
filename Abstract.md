# Docker Machinery - Complete Cluster Control at the Command-Line

machinery tries to be the missing piece at the top of the Docker
pyramid.  machinery is (mostly) a command-line tool that integrates
Machine, Swarm, Compose and Docker itself to manage the lifecycle of
entire clusters.  machinery combines a specifically crafted YAML file
format with compose-compatible files to provide an at-a-glance view of
whole clusters and all of their components.  In addition to its
command-line interface, machinery also provides a REST-like interface
to ease integration and automation with external projects and tools.

Through the provision of an integrated view of entire clusters,
machinery eases tasks such creating or removing virtual machines
hosted at any of the providers supported by Machine, but also managing
the creation or removal of components onto those machines.  Components
can either be pinpointed to specific machines, either be placed onto
the cluster using any of the controlling facilities provided by Swarm.
To quicken component starting in dynamic scenarios, machinery is able
to initialise virtual machines with a number of docker images ready to
be instantiated whenever needed.

Machinery can be used in the development, prototyping and testing
phases by providing quick access to production-like environments, but
also in real production scenarios when ramping up projects.