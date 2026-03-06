# Monty Capability Probe
# Tests every Python feature needed for persistent apps

results = []

# 1. Dict literal + mutation
d = {"a": 1}
d["b"] = 2
results.append(("dict_mutation", d["b"] == 2))

# 2. Dict .get() with default
val = d.get("missing", 42)
results.append(("dict_get_default", val == 42))

# 3. "key" in dict
results.append(("dict_in_operator", "a" in d))
results.append(("dict_not_in", "z" not in d))

# 4. len() on dict
results.append(("dict_len", len(d) == 2))

# 5. for key in dict iteration
keys = []
for k in d:
    keys.append(k)
results.append(("dict_iteration", len(keys) == 2))

# 6. def function
def add(x, y):
    return x + y
results.append(("def_function", add(3, 4) == 7))

# 7. def with default arg
def greet(name, prefix="Hello"):
    return prefix + " " + name
results.append(("def_default_arg", greet("Bob") == "Hello Bob"))

# 8. Closure (function referencing outer scope)
outer = 10
def use_outer():
    return outer + 5
results.append(("closure", use_outer() == 15))

# 9. not operator
results.append(("not_true", not False))
results.append(("not_false", not True == False))

# 10. while loop
counter = 0
while counter < 5:
    counter = counter + 1
results.append(("while_loop", counter == 5))

# 11. while True + break
x = 0
while True:
    x = x + 1
    if x == 3:
        break
results.append(("while_true_break", x == 3))

# 12. List comprehension
nums = [1, 2, 3, 4, 5]
evens = [n for n in nums if n % 2 == 0]
results.append(("list_comprehension", evens == [2, 4]))

# 13. Dict comprehension
squares = {str(n): n * n for n in range(4)}
results.append(("dict_comprehension", squares["3"] == 9))

# 14. First-class function reference
def double(x):
    return x * 2
fn_ref = double
results.append(("first_class_fn", fn_ref(5) == 10))

# 15. Function stored in dict
ops = {"double": double, "add": add}
results.append(("fn_in_dict", ops["double"](3) == 6))

# 16. Function called from dict
result = ops["add"](10, 20)
results.append(("fn_call_from_dict", result == 30))

# 17. Nested dict
nested = {"user": {"name": "Bob", "items": [1, 2, 3]}}
results.append(("nested_dict", nested["user"]["name"] == "Bob"))
results.append(("nested_list_in_dict", len(nested["user"]["items"]) == 3))

# 18. str() and int() conversion
results.append(("str_conversion", str(42) == "42"))
results.append(("int_conversion", int("42") == 42))

# 19. String methods
s = "hello world"
results.append(("str_upper", s.upper() == "HELLO WORLD"))
results.append(("str_startswith", s.startswith("hello")))
results.append(("str_split", len(s.split(" ")) == 2))

# 20. List .append / .pop / .remove
lst = [1, 2, 3]
lst.append(4)
results.append(("list_append", lst == [1, 2, 3, 4]))

# 21. Tuple unpacking
a, b = 10, 20
results.append(("tuple_unpack", a == 10 and b == 20))

# 22. Multiple assignment — NOT SUPPORTED (x = y = 0 fails)
# Skipped: SyntaxError in Monty

# 23. f-string with expression
name = "Dart"
results.append(("fstring_expr", f"{name.upper()}!" == "DART!"))

# 24. Boolean operators
results.append(("bool_and", True and True))
results.append(("bool_or", False or True))

# ── Report ──
passed = 0
failed = 0
for name, ok in results:
    status = "PASS" if ok else "FAIL"
    if ok:
        passed = passed + 1
    else:
        failed = failed + 1
    print(f"  {status}  {name}")

print(f"\n{passed}/{passed + failed} passed")
