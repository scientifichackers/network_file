# Network File

Network File let's you transparently find, 
and share files across several other devices in a network running Network File.

Works anywhere `dart:io` works.

## How?

Network file works like this -

- When a device wants to download a file, (by invoking `NetworkFile.getInstance().findFile()`),
it issues a UDP broadcast request.

- When the UDP broadcast packet reaches a server (created by `NetworkFile.getInstance().run()`),
the server responds if it has the file.

- Once a server responds, the client/server will transfer this file using plain old HTTP.

That's it.
