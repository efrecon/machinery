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