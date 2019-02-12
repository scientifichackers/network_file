# Network File

Network File let's you transparently find, 
and share files across several other devices in a network running Network File.

Works anywhere `dart:io` works.

## How?

Network file works like this -

- When a device wants to download a file, (by invoking `NetworkFile.findFile()`),
it issues a UDP broadcast request.

- When the UDP broadcast packet reaches a server (created by `NetworkFile.runserver()`),
the server responds if it has the file.

- Once a server responds, the client/server will transfer this file using plain old HTTP.

That's it.

## Features

- A `FileIndex` that either works on relative paths, or the MD5 hash of the files.


## Examples

