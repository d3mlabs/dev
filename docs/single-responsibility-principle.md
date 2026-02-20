---
title: Single Responsibility Principle
weight: 0
---

The Single Responsibility Principle (SRP) is usually defined as such:

> **A class should have one, and only one reason to change**.[1] [2]

That definition is often interpreted as decomposition being the ultimate goal: what better way to ensure your class has
only one reason to change than decoupling all behaviour to its smallest unit? This kind of 1-way street thinking leads
to a lack of cohesion by separating behaviour that changes for the same reason into different classes, going against the
very thing the SRP is trying to achieve: increase cohesion. In fact, Robert C. Martin clarified the wording in a blog
post in 2014:

> **Gather together the things that change for the same reasons. Separate those things that change for different
reasons**.[3]

In short, **SRP is a 2-way street – classes that are too broad in responsibility should be made more specific, and
classes that are too specific should be made less specific.**

Read Robert's amendment and the above line again. Let it sink in, really, please do!

> **Applications that are easy to change consist of classes that are easy to reuse. [...] A class that has more than one
responsibility is difficult to reuse**.[4]

**NOTE:** SRP applies not just to classes, but to other units of abstraction, i.e. methods, classes, packages /
components, libraries, services / applications...

## Narrow Responsibility

When an object is too specific, we can say that its responsibility is too narrow.

Narrow responsibility leads to a lack of cohesion and little potential for re-use. A user of said class must look in
different files for operations that seem related. It's easy to be tempted to perpetuate the cycle of narrow
responsibility.

>**Note**
> Recognizing narrow responsibility
> * Proliferation of small objects.
>   * Often felt as unnecessary indirection.
>   * You have to look in different files for operations that are related, rather than looking at what is exposed
>     publicly on an object you're currently using.
> * Objects often only have one public method.
>   * Method may be named in a very generic fashion, i.e. `perform`, `call`, etc…
>   * Parameters for single operation are sometimes passed in the constructor rather than the method.
> * Few or no private methods can be an indicator that the class is on the far extreme of narrow responsibility.

### Bad Example

>**Danger**
>```ruby
>class Foo; end
>
># ./fetch_foo.rb
>class FetchFoo
>  extend(T::Sig)
>
>  sig { params(id: Integer).returns(Foo) }
>  def fetch(id); end
>end
>
># ./add_foo.rb
>class AddFoo
>  extend(T::Sig)
>
>  sig { params(foo: Foo).void }
>  def add(foo); end
>end
>```


### Good Example

`FetchFoo` and `AddFoo` individually have only one reason to change:
- `Foo` / its datastore model changes.

However if either changes, it is very likely that both `FetchFoo` and `AddFoo` must change as well.

**SRP tells us to group these objects together:**

>**info**
> ```ruby
> class Foo; end
>
> class FooRepository
>   extend(T::Sig)
>
>   sig { params(foo: Foo).void }
>   def add(foo); end
>
>   sig { params(id: Integer).returns(Foo) }
>   def fetch(id); end
> end
> ```

## Single Public Method

This is a sign of an object that has a narrow responsibility, especially if it has a generic name for its public method,
like `perform` or `call`. It may also present itself as a class method.

A single public method often leads to naming the class by that single operation, which translates into a narrow
responsibility. Furthermore, it can be tempting to remove redundancy and name the method `perform` or `call`, further
crystallizing the narrow responsibility, i.e. operation `fetch`, which according to the SRP should be grouped with the
`add` operation, can only be added here by significantly refactoring this class:
- Rename the class to have a wider responsibility
- Rename `perform` to `add`
- Add `fetch` operation

It is very easy to miss this potential refactor and cargo-cult the narrow responsibility by creating a new class for
the `fetch` operation.

### Bad Example

`AddFoo` has a too narrow responsibility. It is easy to cargo-cult the narrow responsibility and simply add `FetchFoo`.

>**Danger**
> ```ruby
> class Foo; end
>
> class AddFoo
>   extend(T::Sig)
>
>   # NOTE: This single public instance method can present itself as a class method.
>   sig { params(foo: Foo).void }
>   def perform(foo); end
> end
> ```
> ```diff
> +class FetchFoo
> +  extend(T::Sig)
> +
> +  sig { params(id: Integer).void }
> +  def perform(id); end
> +end
> ```


### Good Example

This object is not crystallized in a single narrow responsibility. It is easy to add operations that should be grouped
together because they change for the same reasons.

>**Info**
>```diff
>class Foo; end
>
>class FooRepository
>  sig { params(foo: Foo).void }
>  def add(foo); end
>
>  # Because the responsibility of this object is just right, it is natural to add operations
>  # like these in the future:
>+  sig { params(id: Integer).returns(Foo) }
>+  def fetch(id); end
>end
>```


## Single Public Method with All Parameters Passed to the Constructor

Passing all parameters to the constructor, with a single method that takes no parameters but uses the parameters passed
in the constructor.

This perpetuates the cycle of locking objects into their single narrow responsibility.

### Bad Example

Cannot add another functionality to this class unless the same params all apply to the other operation. Grouping a new
operation like `FetchFoo` with `AddFoo` is not possible without a significant refactor.

**Danger**
>```ruby
>class Foo; end
>
>class AddFoo
>  extend(T::Sig)
>
>  sig { params(foo: Foo).void }
>  def initialize(foo)
>    @foo = foo
>  end
>
>  sig { void }
>  def perform
>    do_something_with_all_params(@foo)
>  end
>end
>
># AddFoo instance is so specific that it has almost no potential for being re-used; it must be re-allocated every time.
>AddFoo.new(Foo.new).perform
>```


### Good Example
Prefer a less narrow responsibility around what risks changing for the same reasons.

This object is not crystallized in a single narrow responsibility. It is easy to add operations that should be grouped
together because they change for the same reasons.

>**Info**
>```diff
>class Foo; end
>
>class FooRepository
>  sig { params(foo: Foo).void }
>  def add(foo); end
>
>  # Because the responsibility of this object is just right, it is natural to add operations
>  # like these in the future:
>+  sig { params(id: Integer).returns(Foo) }
>+  def fetch(id); end
>end
>```

## Single Public Class Method (Static Method)

This is a sign of an "object" that has a narrow responsibility, especially so if its public method has a generic name,
like `perform` or `call`.

**NOTE**: There is a use case for class methods, i.e. DSLs, utility functions, etc...

### Bad Example

A class method crystallizes the narrow responsibility, in that it's now not easily possible to extend the class to take
in dependencies for the existing method, unless it's first refactored to an instance method.

>**Danger
> ```ruby
> class Foo; end
> class DatabaseContext; end
>
> class FooRepository
>   extend(T::Sig)
>
>   sig { params(foo: Foo).void }
>   def self.add(foo); end
> end
> ```

### Good Example

Prefer an instance method which allows injecting dependencies in the future.

>**Info**
> ```ruby
> class Foo; end
> class DatabaseContext; end
>
> class FooRepository
>   extend(T::Sig)
>
>   # One could very well imagine that this object could take in a database context dependency in the future, abstracting
>   # the concern of which datastore to use.
>   sig { params(db_context: DatabaseContext) }
>   def initialize(db_context); end
>
>   sig { params(foo: Foo).void }
>   def add(foo); end
> end
> ```

## Wide Object Responsibility

An object whose responsibility is too wide leads to so-called "god objects" that do everything and make it hard to
understand what's going on.

### Bad Example

This class has too many responsibilities; there are multiple reasons for change:
- Foo / its datastore model changes.
- Bar / its datastore model changes.

It looks like a repository for different aggregates.

>**Danger**
> ```ruby
> class Foo; end
> class Bar; end
>
> class FooBarService
>   extend(T::Sig)
>
>   sig { params(foo: Foo).returns(Foo) }
>   def add_foo(foo); end
>
>   sig { params(id: Integer).returns(Foo) }
>   def fetch_foo(id); end
>
>   sig { params(bar: Bar).returns(Foo) }
>   def add_bar(bar); end
>
>   sig { params(id: Integer).returns(Bar) }
>   def fetch_bar(id); end
> end
> ```

### Good Example

Object responsibility is right, which increases cohesion. Things that risk changing together are grouped together.

>**Info**
> ```ruby
> class Foo; end
> class Bar; end
>
> class FooRepository
>   extend(T::Sig)
>
>   sig { params(foo: Foo).void }
>   def add(foo); end
>
>   sig { params(id: Integer).returns(Foo) }
>   def fetch(id); end
> end
>
> class BarRepository
>   extend(T::Sig)
>
>   sig { params(bar: Bar).void }
>   def add(bar); end
>
>   sig { params(id: Integer).returns(Bar) }
>   def fetch(id); end
> end
> ```

## References

1. Martin, R. C. (2003). In Agile software development: Principles, patterns, and practices (p. 95)., Prentice Hall.
2. Martin, R. C. (2005). The Principles of OOD. http://www.butunclebob.com/ArticleS.UncleBob.PrinciplesOfOod
3. Martin, R. C. (2014). The Single Responsibility Principle. https://blog.cleancoder.com/uncle-bob/2014/05/08/SingleReponsibilityPrinciple.html
4. Metz, S. (2018). Designing Classes with a Single Responsibility. In Practical Object-Oriented Design in Ruby: an Agile Primer (2nd ed., p. 21). Pearson Technology Group Canada.

