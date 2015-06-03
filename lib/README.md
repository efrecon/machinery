# Resolving dependencies

`machinery` has few dependencies and tries to be self-contained as
much as possible.  However, to benefit from the web API, you will need
to arrange for the `til` to be accessible from this directory.  Just
issue the following command in this directory is enough:

    git clone https://github.com/efrecon/til

The web server in the `til` relies on the logger module from `tcllib`,
meaning that you will also need `tcllib` installed on your system.
But this is anyhow already needed for YAML parsing.