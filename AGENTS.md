# AGENTS.md

## Berry Language Introduction
Berry is a ultra-lightweight dynamically typed embedded scripting language. It is designed for lower-performance embedded devices.

The interpreter of Berry include a one-pass compiler and register-based VM. In Berry not every type is a class object. Some simple value types, such as int, real, boolean and string are not class object, but list, map and range are class object. This is a consideration about performance. Register-based VM is the same meaning as above.

Berry has the following advantages:
   * Lightweight: A well-optimized interpreter with very little resources. Ideal for use in microprocessors.
   * Fast: optimized one-pass bytecode compiler and register-based virtual machine.
   * Powerful: supports imperative programming, object-oriented programming, functional programming.
   * Flexible: Berry is a dynamic type script, and it's intended for embedding in applications. It can provide good dynamic scalability for the host system.
   * Simple: simple and natural syntax, support garbage collection, and easy to use FFI (foreign function interface).
   * RAM saving: With compile-time object construction, most of the constant objects are stored in read-only code data segments, so the RAM usage of the interpreter is very low when it starts.

### Features
Base Type
    * Nil: ``nil``
    * Boolean: ``true`` and ``false``
    * Numerical: Integer (``int``) and Real (``real``)
    * String: Single quotation-mark string and double quotation-mark string
    * Class: Instance template, read only
    * Instance: Object constructed by class
    * Module: Read-write key-value pair table
    * List: Ordered container, like ``[1, 2, 3]``
    * Map: Hash Map container, like ``{ 'a': 1, 2: 3, 'map': {} }``
    * Range: include a lower and a upper integer value, like ``0..5``
Operator and Expression
    * Assign operator: ``=``, ``+=``, ``-=``, ``*=``, ``/=``, ``%=``, ``&=``, ``|=``, ``^=``, ``<<=``, ``>>=``
    * Relational operator: ``<``, ``<=``, ``==``, ``!=``, ``>``, ``>=``
    * Logic operator: ``&&``, ``||``, ``!``
    * Arithmetic operator: ``+``, ``-``, ``*``, ``/``, ``%``
    * Bitwise operator: ``&``, ``|``, ``~``, ``^``, ``<<``, ``>>``
    * Field operator: ``.``
    * Subscript operator: ``[]``
    * Connect string operator: ``+``
    * Conditional operator: condition ``?`` val_true ``:`` val_false
    * Brackets: ``()``
    * Bytes buffer support
Control Structure
    * Conditional statement: ``if`` ``elif`` ``else`` ``end``
    * Iteration statement: ``while``, ``for``
    * Jump statement: ``break``, ``continue``
Function
    * Local variable and block scope
    * Return statement
    * Nested functions definition
    * Closure based on Upvalue
    * Anonymous function
    * Lambda expression
Class
    * Inheritance (only public single inheritance)
    * Method and Operator Overload
    * Constructor method
    * Destructive method
Module Management
    * Built-in module that takes almost no RAM
    * Extension module support: script module, bytecode file module and shared library (like \*.so, \*.dll) module
    * Ability to solidify code, classes and modules in flash to reduce RAM usage
    * Optional Regex support
    * Optional LVGL mapping
GC (Garbage collection)
    * Mark-Sweep GC
Exceptional Handling
    * Throw any exception value using the ``raise`` statement
    * Multiple catch mode
Bytecode file support
    * Export function to bytecode file
    * Load the bytecode file and execute
Native C interface
    * Can be easily embedded as a library in existing code like Tasmota
    * Optional easy mapping to call C code from Berry

## Berry Coding Conventions
### Comments
- Use `#` for single-line comments. Place a space after `#`.
- Comments should be clear and concise, explaining non-obvious logic.

### Naming
- Use `snake_case` for variables and functions.
- Use `PascalCase` for class names.
- Use all-uppercase with underscores for constants (e.g., `MAX_SIZE`).

### Indentation & Formatting
- Indentation is not required by the Berry compiler, but use 2 spaces per level for readability.
- Do not use tabs.
- Separate statements with whitespace (space, tab, or newline).

### Literals
- Lists: `[]` (empty), `[1, 2, 3]` (with values)
- Maps: `{}` (empty), `{ "k1": "v1", "k2": "v2" }`
- Strings: Use double quotes, e.g., `"hello"`
- Booleans: `true`, `false`
- Nil: `nil`

### Types
- Berry is dynamically typed. Do not annotate types in function signatures or variable declarations.
- Use `isinstance(obj, ClassName)` to check types if needed.

### Error Handling
- Use idiomatic Berry error handling (e.g., check for `nil` or use try/catch if available in your Berry environment).

## Berry Language Idioms & Examples

### Functions
- Define functions with `def` and end with `end`.
- Arguments are untyped and default to `nil` if not provided.
- Example:
  ```berry
  def greet(name)
    print("Hello, " + str(name))
  end
  
  greet("Berry")
  ```

### Classes & Objects
- Define classes with `class` and end with `end`.
- Use `var` for instance variables.
- The constructor is always `def init(...) ... end`.
- Example:
  ```berry
  class Greeter
    var name
    def init(name)
      self.name = name
    end
    def say_hi()
      print("Hi " + self.name)
    end
  end
  
  greeter = Greeter("Pat")
  greeter.say_hi()
  ```

### Control Flow
- If statement:
  ```berry
  if x > 0
    print("Positive")
  end
  ```
- For loop over range:
  ```berry
  for i: 0..4
    print(i)
  end
  ```
- For loop over list:
  ```berry
  for item: my_list
    print(item)
  end
  ```

### Collections
- Lists: `[1, 2, 3]`
- Maps: `{ "k": "v" }`
- Access: `my_map["k"]`
- Check key: `my_map.contains("k")`
- Iterate keys: `for k: my_map.keys() ... end`
- Maps do NOT have a `.values()` method. To iterate values, iterate keys and look up each value.

### String Formatting
- Use `string.format()` for formatted strings:
  ```berry
  import string
  print(string.format("Hello, %s!", name))
  ```

### Closures
- Define closures with `def () ... end` syntax.
- Example:
  ```berry
  cb = def () print("Callback!") end
  cb()
  ```

## General AI Code Generation Guidelines
- Always generate code that is idiomatic and consistent with Berry conventions outlined above.
- Prioritize clarity, maintainability, and simplicity in all generated code.
- Add comments for non-obvious logic, but avoid excessive or redundant comments.
- Use descriptive names for variables, functions, and classes.
- Prefer explicitness over implicit behavior, especially in control flow and data structures.
- Avoid unnecessary complexity or cleverness; favor straightforward solutions.
- Ensure that all code examples are complete and runnable where possible.
- When in doubt, refer to the official Berry documentation: https://berry.readthedocs.io/en/latest/
- Berry dynamically allocates memory for variables and data structures as needed. Complex scripts, excessive dynamic allocation, or memory leaks within a script can lead to instability, out-of-memory errors, and crashes. Write efficient and concise Berry code, avoiding unnecessary variables or complex data structures.
