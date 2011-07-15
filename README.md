========================================================================
Agda compiler backend to Ruby
========================================================================

This is a bunch of hack edits over a couple of days to the Agda Javascript backend written by [Alan Jeffrey](http://github.com/asajeffrey).

Examples
--------

https://gist.github.com/1083978

* Agda modules are compiled to Ruby modules.
* All arguments are curried.
* You can store and pass around "Agda" values/constructors/etc, and then "realize" the values in Ruby by calling the final value with its realizer constant (e.g. `NAT`, `VEC`, etc.)


Compiling
---------

To compile Agda code to Javascript, use `--js` on the `master` branch.
To compile to Ruby instead, switch to the `ruby` branch and use the `--js` flag (easy to change this to --rb, but was useful in development to quickly compare Javascript and Ruby output).

Use Case
--------

Assuming a completed/fully functioning backend, it would be nice for Ruby shops to be able to reuse existing code that would be too much trouble to rewrite (authentication/client libaries, etc). Also a project like [Lemmachine](github.com/larrytheliquid/Lemmachine) could be ported to Ruby's Rack interface, allowing one to easily deploy to many different Ruby hosting providers (Engine Yard, Heroku, etc).

