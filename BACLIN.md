# BACLIN - BAsic Compose LINeariser

This utility will linearise a file in the Docker [Compose][1] format so that all
occurrences of [extends][2] directives are recursively replaced by the service
definitions that they point at. It has been writter to circumvent issue
[#31101][3], i.e. to palliate the removal of `extends` directive between version
2 and version 3 of the compose file format.

Using this tool, you should be able to write `extends` directives in your
compose 3 files, and linearise them before sending to the swarm using `docker
stack deploy`. Obviously, these files would *not* comply to version 3+ of the
file format specification as it lacks support for `extend`.

The tool takes two arguments on the command line: the path to the input file and
the path to the output file. Each argument can be replaced by a `-`, meaning
reading from standard in or writing to standard out. Empty (or missing)
arguments will have the same meaning as the use of the more explicit dash. When
reading from the standard input, `baclin` will default to the current directory
as the root for relative file specifications that could happen in `extends`
directives.

  [1]: https://docs.docker.com/compose/compose-file/
  [2]: https://docs.docker.com/compose/compose-file/compose-file-v2/#extends
  [3]: https://github.com/moby/moby/issues/31101
  
## Example

Provided a main compose file with the following content:

````
version: 3

services:
    web:
      extends:
        file: ../common.yml
        service: webapp
      environment:
        - DEBUG=1
      cpu_shares: 5

    important_web:
      extends: web
      cpu_shares: 10
````

And the file at `../common.yml` containing:

````
version: 2

services:
    common:
        labels:
            se.sics.copyright: "Emmanuel Frecon"
            se.sics.organisation: "RISE SICS"
    webapp:
        extends: common
        labels:
            se.sics.application: "Web"
        image: nginx
        ports:
          - "8000:8000"
        volumes:
          - "/data"
        environment:
            - TEST=34
````

Running `baclin` on the main file would lead to the following content:

````
version: 3
services:
  web:
    labels:
      se.sics.copyright: Emmanuel Frecon
      se.sics.organisation: RISE SICS
      se.sics.application: Web
    image: nginx
    ports:
      - 8000:8000
    volumes:
      - /data
    environment:
      - TEST=34
      - DEBUG=1
    cpu_shares: 5
  important_web:
    labels:
      se.sics.copyright: Emmanuel Frecon
      se.sics.organisation: RISE SICS
      se.sics.application: Web
    image: nginx
    ports:
      - 8000:8000
    volumes:
      - /data
    environment:
      - TEST=34
      - DEBUG=1
    cpu_shares: 10
````

## Binaries

Binaries, automatically generated using [make.tcl][4] ar available [here][5].

  [4]: https://github.com/efrecon/machinery/blob/master/make/make.tcl
  [5]: https://bintray.com/efrecon/baclin/baclin/0.1#files