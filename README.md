# Fluent Phantom 
A fluent interface for scraping web content in Node with the PhantomJS headless browser.  Its most notable feature is that, similar to waitFor.js, you can wait until the availability of content on a page, which comes in handy when scraping content generated by AJAX requests.

## Installation
Install via npm with:
```
npm install fluent-phantom
```

Note that this package depends on the [PhantomJS bridge for Node](https://github.com/sgentle/phantomjs-node), which assumes that you have already installed [PhantomJS](http://phantomjs.org/).

## Basic Example
The most likely scenario for usage – scraping content dynamically generated by the client using a CSS selector – is outlined in CoffeeScript below. For more information, read the rest of this document.

```
phantom = require 'fluent-phantom'`
phantom.create()
	.select('#headlines h3')
	.from('http://example.com/news')
	.and().process((elements) -> 
		for element in elements
			new Headline(element.innerText).save()
	)
	.with().members('innerText')
	.until(5000) # Timeout after 5 seconds
	.otherwise(-> 
		throw Error "Headlines were never loaded"
	)
	.execute()
```

## Overview
This package is made up of two classes: a `Request` class that wraps the PhantomJS bridge and a fluent `Builder` to simplify its use.

- [Builder](#builder)
  	- [Initializing a builder with `create()`](#initializing)
	- [Declaring a URL with `from()`](#from)
    - Scraping content
		- [With CSS selectors](#scrape-css)
			- [`select()`](#select-css)
			- [`handle()`](#handle)
			- [`properties()`](#properties)
		- [With functions](#scrape-function)
			- [`select()`](#select-function)
			- [`evaluate()`](#evaluate)
			- [`run()`](#run)
	- [Waiting for content with `when()`](#waiting)
		- [With CSS selectors](#when-css)
		- [With functions](#when-functions)
	- [Controlling timeouts and errors](#timeouts-and-errors)
		- [`otherwise()`](#otherwise)
		- [`timeout()`](#timeout)
		- [`forever()`](#forever)
		- [`immediately()`](#immediately)
	- [Filler terms](#filler)
	- [Finishing with `build()` and `execute()`](#building)
- [Request](#request)
	- Setters and getters
	- Debugging
	- Events

## Builder <a name="builder" />
### Initializing a builder with `create()` <a name="initializing" />
Builders can be created with `new`, but using the package-level `create()` helper is encouraged, as in the following example:
```coffeescript
phantom = require 'fluent-phantom'
builder = phantom.create()
```

### Declaring a URL with `from()` <a name="from" />
#### Builder.from(url: string)
Synonyms: `url()`

Sets the request URL.
```coffeescript
phantom.create().from('http://example.com/')
```

### Scraping content with CSS selectors <a name="scrape-css" />
The easiest way to scrape content is to call `select()` with a CSS selector and let the library generate your scraping code for you. This will automatically wait until the number of elements found with this selector is greater than zero by immediately invoking `when()`. Optionally, the members of nodes in the result set can be limited using `properties()`.

Here is an example of extracting all `h3` elements in a container with the id 'headlines':

```coffeescript
phantom.create()
	.select('#headlines h3')
	.from('http://example.com/news')
	.and().process((elements) -> console.log "Handle results here", elements)
	.with().members('innerHTML', 'className', 'id')
	.until(5000) # Timeout after 5 seconds
	.otherwise(-> console.error "The selector was never satisfied; handle errors here")
	.execute()
```

#### Builder.select(selector: string, [minimum: number]) <a name="select-css" />
Synonyms: `extract()`

See also: [`when()`](#when-css), [`properties()`](#properties), [`handle()`](#handle)

When `select` is invoked with a string, it is assumed to be a CSS selector describing elements to be scraped. When used in this way, `select` will immediately invoke [`when`](#when-css) to automatically wait for the selector to be satisfied. If a number is passed as the second argument, it is treated as a minimum number of elements that must be satisfied and passed to `when`.

Note that WebKit's `document.querySelectorAll()` is used to interpret selectors.

#### Builder.handle(callback: function) <a name="handle" />
Synonyms: `process()`, `receive()`

Specify a callback function to process results. Because scraping performed by `select` happens inside the PhantomJS VM, the results must be serialized to JSON and processed by a function in the Node.js VM where this module is being used. This is where you would publish results to a message queue or persist them to a data store.

The callback will receive one arguments, which will be an array of results – even if there is only one result in the set.

#### Builder.properties(property: string, [property2: string], [...]) or Builder.properties(properties: array) <a name="properties" />
Synonyms: `members()`

By default, elements in the result set are stripped down to a handful of properties: `id`, `children`, `className`, `innerHTML`, and a few others. This list can be expanded or contracted by invoking the `properties` method with a list of property names as strings. They should be valid DOM properties.


### Scraping content with functions <a name="scrape-function" />
Sometimes, a simple CSS selector is not enough to describe the content you want to scrape. The `Builder` provides several alternatives that allow greater expression.

#### Builder.select(extractor: function, [argument: any]) <a name="select-function" />
Synonyms: `extract()`

See also: [`when()`](#when-function), [`handle`](#handle)

The `select` method can also accept a function as its first argument. This function will run in the context of the page being scraped within the PhantomJS VM, and its return value will be passed as the first and only argument to [`handle`](#handle) for further processing. 

Because the function body is effectively serialized and deserialized, any closed over variables will be lost. To allow for some dynamism, a JSON-serializable argument may be provided like a CSS selector or a record identifier. This argument will be the first and only passed to the extractor function when invoked.

Note that using `select` with a function rather than a CSS selector overrides the use of [`properties`](#properties), and does not automatically cause the `Request` to wait until content is ready. Also note that references in the PhantomJS VM – including those to DOM elements – do not serialize as you might expect. For best results, be sure to return values, not references.

Because DOM elements are references within the PhantomJS VM, in the example below, you won't receive a long list of DOM elements as you might expect:
```coffeescript
phantom.create()
	.select(->
		document.querySelectorAll '#headlines h3'
	)
	# ...
```

To work around this, return values instead of references, like so:
```coffeescript
phantom.create()
	.select(->
		# Returns an array of objects of the form {id: ..., text: ...}
		for elem in document.querySelectorAll '#headlines h3'
			id: elem.id
			text: elem.innerText
	)
	# ...
```

#### Builder.evaluate(extractor: function, handler: function, [argument: any]) <a name="evaluate" />
See also: [`select(function)`](#select-function)

Assign an extractor function and a handler in one method call. The result is the same as calling [`select(extractor, argument)`](#select-function) and [`handle(handler)`](#handler).

This method is named evaluate because it wraps `page.evaluate` in the PhantomJS bridge.

#### Builder.run(function) <a name="run" />
Synonyms: `invoke()`

For those who already know what they're doing with PhantomJS and only want the convenience of using this module to wait for content to be available, this method accepts a function that receives a PhantomJS `page` object as its only argument for use with, for instance, `page.evaluate`. Use of this is exclusionary to the use of [`select`](#select-function) and [`evaluate`](#evaluate).

### Waiting for content <a name="waiting" />

### With CSS selectors
The two forms of `when` cause any actions specified by [`handle`](#handle), [`evaluate`](#evaluate), or [`run`](#run) to be suspended until a sentry condition is satisfied or the timeout period set with [`timeout`] has ellapsed. The author's original motivation for using PhantomJS over HTMLUnit or Beautiful Soup was to scrape content generated client-side via a long-polling mechanism. The `when` method is ideal for this as it delays scraping until the content to be scraped is available.

When a sentry condition has been set, the Request will test for it immediately and every ~250ms afterwards until it has been satisfied or the test times out. At each check, the Request will emit the 'checking' event.

#### Builder.when(selector: string, [minimum: number]) <a name="wait-css" />
See also: [`select()`](#select-css), [`timeout()`](#timeout)

Causes execution to be delayed until the document has at least one element satisfying the provided CSS selector using `document.querySelectorAll()`. If a minimum is provided, execution will be delayed until the minimum has been reached.

This form of `when` is automatically invoked when using `select` with a CSS selector.

### With functions
#### Builder.when(sentry: function, [argument: any]) <a name="wait-function" />
See also: [`select()`](#select-function), [`timeout()`](#timeout)

Causes execution to be delayed until the sentry function provided returns true. The function will be invoked in the context of the page within the PhantomJS runtime and, as described in the documention for [using `select` with functions](#select-function), any closed over scope will be lost. A second, JSON-serializable parameter may be provided to be passed as the first argument to the sentry function when invoked.

If multiple parameters are needed, pass them in one object, as is done in this adaptation from the source for `Builder.when()`:
```coffeescript
argument =
	minimum: minimum
	query: condition

callback = (args) -> document.querySelectorAll(args.query).length >= args.minimum

builder.when(callback, argument)
```

### Controlling timeouts and errors <a name="timeouts-and-errors" />
Builders provide support for setting bounds on the time to wait for content to become ready.

#### Builder.otherwise(callback: function) <a name="otherwise" />
Set a callback to be invoked when the request times out while waiting for content to become available. The callback will receive no arguments.

#### Builder.timeout(milliseconds: number) <a name="timeout" />
Synonyms: `for()`, `until()`

Set the duration to wait before timing out.

#### Builder.forever() <a name="forever" />
Allow a request to wait forever for content.

#### Builder.immediately() <a name="immediately" />
Causes the request to test its condition once, but only once.

### Filler terms <a name="filler" />
For expressiveness, several meaningless terms exist in the builder grammar. They are:
 * `and()`
 * `then()`
 * `of()`
 * `with()`

These terms provide a more fluent feel. For instance, compare the following two examples:
```coffeescript
# Vanilla
phantom.create()
	.select('div.feature a')
	.process(-> ...)
```

```coffeescript
phantom.create()
# Slightly more expressive
	.select('div.feature a')
	.and().then().process(-> ...)
```

The difference is small, but available if desired.

### Finishing with `build()` and `execute()` <a name="building" />
Once a builder has received all input to create a request, you can build it using `build()` or immediately execute (and return) it with `execute()`.

#### Builder.build() <a name="build" />
Builds a [`Request`](#request) object to your specifications.

#### Builder.execute() <a name="execute" />
Builds and immediately executes a new [`Request`](#request) object. The `Request` is returned.

## Request <a name="request" />
Documentation coming soon. In the meantime, view the annotated source in its [raw form](index.coffee) or [prettied up by docco](docs/index.html).



