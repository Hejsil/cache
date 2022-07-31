# cache

Can wrap any command line tool to provide caching for the output of that tool.

## Example

```sh
$ # We can use curl to get the weather data from wttr.in
$ curl -s 'https://wttr.in/'
...

$ # Caching this command is simple. It only depends on the arguments of the command,
$ # and outputs to stdout
$ cache -- curl -s 'https://wttr.in/'
...

$ # Now, this is cached and will never be invalidated (unless you delete
$ # ~/.cache/cache). We can specify that the command depends on external data. Let's
$ # have it depend on the output of `date`, so the cache is invalidated each day
$ cache -s "$(date +%Y-%m-%d)" -- curl -s 'https://wttr.in/'
...

$ # You can mark a command to depend on different things like environment variables
$ # (-e), files (-f) or even stdin (--stdin).

$ # cache can also handle if a command outputs to one or more files. You need to
$ # manually list the files the command will output
$ cache -o test -- gcc -o test test.c
```
