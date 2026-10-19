// Generated file — do not edit.
// Oracle: pydantic-monty 1.1.0.
// Regenerate with: dart run tool/bake_error_parity.dart.

/// The upstream oracle version recorded in `cases.json`.
const String errorParityOracle = 'pydantic-monty 1.1.0';

/// Raw JSON contents of `test/fixtures/error_parity/cases.json`.
const String errorParityCasesJson = r'''
{
 "oracle": "pydantic-monty 1.1.0",
 "cases": [
  {
   "id": "b12_execute_raise__raise_type_direct",
   "code": "# raise exception type directly\nraise ValueError\n# Raise=ValueError()\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 7,
        "end_line": 2,
        "end_column": 17,
        "function": "<module>",
        "source_line": "raise ValueError"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 2, in <module>\n    raise ValueError\nValueError",
      "type-msg": "ValueError",
      "msg": "",
      "str": "ValueError",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": ""
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "04_raise_from_explicit_cause",
   "code": "def outer_step():\n    try:\n        int('not-a-number')\n    except ValueError as cause:\n        raise RuntimeError('explicit cause failure') from cause\n\nouter_step()",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "RuntimeError",
      "message": "explicit cause failure",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 7,
        "column": 1,
        "end_line": 7,
        "end_column": 13,
        "function": "<module>",
        "source_line": "outer_step()"
       },
       {
        "filename": "<python-input-0>",
        "line": 5,
        "column": 15,
        "end_line": 5,
        "end_column": 53,
        "function": "outer_step",
        "source_line": "        raise RuntimeError('explicit cause failure') from cause"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 7, in <module>\n    outer_step()\n    ~~~~~~~~~~~~\n  File \"<python-input-0>\", line 5, in outer_step\n    raise RuntimeError('explicit cause failure') from cause\nRuntimeError: explicit cause failure",
      "type-msg": "RuntimeError: explicit cause failure",
      "msg": "explicit cause failure",
      "str": "RuntimeError: explicit cause failure",
      "exception": {
       "type": "RuntimeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "explicit cause failure"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "05_raise_implicit_context",
   "code": "def handle_bad():\n    try:\n        1 / 0\n    except ZeroDivisionError:\n        raise KeyError('failed during recovery')\n\nhandle_bad()",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "KeyError",
      "message": "failed during recovery",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 7,
        "column": 1,
        "end_line": 7,
        "end_column": 13,
        "function": "<module>",
        "source_line": "handle_bad()"
       },
       {
        "filename": "<python-input-0>",
        "line": 5,
        "column": 15,
        "end_line": 5,
        "end_column": 49,
        "function": "handle_bad",
        "source_line": "        raise KeyError('failed during recovery')"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 7, in <module>\n    handle_bad()\n    ~~~~~~~~~~~~\n  File \"<python-input-0>\", line 5, in handle_bad\n    raise KeyError('failed during recovery')\nKeyError: failed during recovery",
      "type-msg": "KeyError: failed during recovery",
      "msg": "failed during recovery",
      "str": "KeyError: failed during recovery",
      "exception": {
       "type": "KeyError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "failed during recovery"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "06_raise_from_none",
   "code": "def clean_api():\n    try:\n        1 / 0\n    except ZeroDivisionError:\n        raise ValueError('public error with suppressed context') from None\n\nclean_api()",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "public error with suppressed context",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 7,
        "column": 1,
        "end_line": 7,
        "end_column": 12,
        "function": "<module>",
        "source_line": "clean_api()"
       },
       {
        "filename": "<python-input-0>",
        "line": 5,
        "column": 15,
        "end_line": 5,
        "end_column": 65,
        "function": "clean_api",
        "source_line": "        raise ValueError('public error with suppressed context') from None"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 7, in <module>\n    clean_api()\n    ~~~~~~~~~~~\n  File \"<python-input-0>\", line 5, in clean_api\n    raise ValueError('public error with suppressed context') from None\nValueError: public error with suppressed context",
      "type-msg": "ValueError: public error with suppressed context",
      "msg": "public error with suppressed context",
      "str": "ValueError: public error with suppressed context",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "public error with suppressed context"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "lambda_failure_display",
   "code": "f = lambda x: 10 // x\nf(0)",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ZeroDivisionError",
      "message": "division by zero",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 1,
        "end_line": 2,
        "end_column": 5,
        "function": "<module>",
        "source_line": "f(0)"
       },
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 15,
        "end_line": 1,
        "end_column": 22,
        "function": "<lambda>",
        "source_line": "f = lambda x: 10 // x"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 2, in <module>\n    f(0)\n    ~~~~\n  File \"<python-input-0>\", line 1, in <lambda>\n    f = lambda x: 10 // x\n                  ~~~~~~~\nZeroDivisionError: division by zero",
      "type-msg": "ZeroDivisionError: division by zero",
      "msg": "division by zero",
      "str": "ZeroDivisionError: division by zero",
      "exception": {
       "type": "ZeroDivisionError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "division by zero"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "comprehension_failure_display",
   "code": "[10 // x for x in [2, 0, 1]]",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ZeroDivisionError",
      "message": "division by zero",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 2,
        "end_line": 1,
        "end_column": 9,
        "function": "<module>",
        "source_line": "[10 // x for x in [2, 0, 1]]"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 1, in <module>\n    [10 // x for x in [2, 0, 1]]\n     ~~~~~~~\nZeroDivisionError: division by zero",
      "type-msg": "ZeroDivisionError: division by zero",
      "msg": "division by zero",
      "str": "ZeroDivisionError: division by zero",
      "exception": {
       "type": "ZeroDivisionError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "division by zero"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "genexp_next_no_try",
   "code": "x = [1, 2]\ny = next((c for c in x if c > 5), None)\nprint(y)\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "TypeError",
      "message": "'list' object is not an iterator",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 5,
        "end_line": 2,
        "end_column": 40,
        "function": "<module>",
        "source_line": "y = next((c for c in x if c > 5), None)"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 2, in <module>\n    y = next((c for c in x if c > 5), None)\n        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\nTypeError: 'list' object is not an iterator",
      "type-msg": "TypeError: 'list' object is not an iterator",
      "msg": "'list' object is not an iterator",
      "str": "TypeError: 'list' object is not an iterator",
      "exception": {
       "type": "TypeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "'list' object is not an iterator"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "genexp_next_in_try",
   "code": "x = [1, 2]\ntry:\n    y = next((c for c in x if c > 5), None)\n    print(y)\nexcept ValueError as e:\n    print(\"err\")\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "TypeError",
      "message": "'list' object is not an iterator",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 6,
        "column": 5,
        "end_line": 6,
        "end_column": 17,
        "function": "<module>",
        "source_line": "    print(\"err\")"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 6, in <module>\n    print(\"err\")\nTypeError: 'list' object is not an iterator",
      "type-msg": "TypeError: 'list' object is not an iterator",
      "msg": "'list' object is not an iterator",
      "str": "TypeError: 'list' object is not an iterator",
      "exception": {
       "type": "TypeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "'list' object is not an iterator"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "b12_traceback__nested_call",
   "code": "def foo():\n    raise ValueError('xxx')\n\n\ndef bar():\n    foo()\n\n\ndef baz():\n    bar()\n\n\nbaz()\n\"\"\"\nTRACEBACK:\nTraceback (most recent call last):\n  File \"traceback__nested_call.py\", line 13, in <module>\n    baz()\n    ~~~~~\n  File \"traceback__nested_call.py\", line 10, in baz\n    bar()\n    ~~~~~\n  File \"traceback__nested_call.py\", line 6, in bar\n    foo()\n    ~~~~~\n  File \"traceback__nested_call.py\", line 2, in foo\n    raise ValueError('xxx')\nValueError: xxx\n\"\"\"\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "xxx",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 13,
        "column": 1,
        "end_line": 13,
        "end_column": 6,
        "function": "<module>",
        "source_line": "baz()"
       },
       {
        "filename": "<python-input-0>",
        "line": 10,
        "column": 5,
        "end_line": 10,
        "end_column": 10,
        "function": "baz",
        "source_line": "    bar()"
       },
       {
        "filename": "<python-input-0>",
        "line": 6,
        "column": 5,
        "end_line": 6,
        "end_column": 10,
        "function": "bar",
        "source_line": "    foo()"
       },
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 11,
        "end_line": 2,
        "end_column": 28,
        "function": "foo",
        "source_line": "    raise ValueError('xxx')"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 13, in <module>\n    baz()\n    ~~~~~\n  File \"<python-input-0>\", line 10, in baz\n    bar()\n    ~~~~~\n  File \"<python-input-0>\", line 6, in bar\n    foo()\n    ~~~~~\n  File \"<python-input-0>\", line 2, in foo\n    raise ValueError('xxx')\nValueError: xxx",
      "type-msg": "ValueError: xxx",
      "msg": "xxx",
      "str": "ValueError: xxx",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "xxx"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "b12_loop__break_outside_error",
   "code": "break\n\"\"\"\nTRACEBACK:\nTraceback (most recent call last):\n  File \"loop__break_outside_error.py\", line 1\n    break\n    ~~~~~\nSyntaxError: 'break' outside loop\n\"\"\"\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "SyntaxError",
      "message": "'break' outside loop",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 1,
        "end_line": 1,
        "end_column": 6,
        "function": null,
        "source_line": "break"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontySyntaxError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 1\n    break\n    ~~~~~\nSyntaxError: 'break' outside loop",
      "type-msg": "SyntaxError: 'break' outside loop",
      "msg": "'break' outside loop",
      "str": "'break' outside loop",
      "exception": {
       "type": "SyntaxError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "'break' outside loop"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "b12_loop__continue_outside_error",
   "code": "continue\n\"\"\"\nTRACEBACK:\nTraceback (most recent call last):\n  File \"loop__continue_outside_error.py\", line 1\n    continue\n    ~~~~~~~~\nSyntaxError: 'continue' not properly in loop\n\"\"\"\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "SyntaxError",
      "message": "'continue' not properly in loop",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 1,
        "end_line": 1,
        "end_column": 9,
        "function": null,
        "source_line": "continue"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontySyntaxError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 1\n    continue\n    ~~~~~~~~\nSyntaxError: 'continue' not properly in loop",
      "type-msg": "SyntaxError: 'continue' not properly in loop",
      "msg": "'continue' not properly in loop",
      "str": "'continue' not properly in loop",
      "exception": {
       "type": "SyntaxError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "'continue' not properly in loop"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "b12_import__error_module_not_found",
   "code": "import nonexistent_module\n\n\"\"\"\nTRACEBACK:\nTraceback (most recent call last):\n  File \"import__error_module_not_found.py\", line 1, in <module>\n    import nonexistent_module\nModuleNotFoundError: No module named 'nonexistent_module'\n\"\"\"\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ModuleNotFoundError",
      "message": "No module named 'nonexistent_module'",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 1,
        "end_line": 1,
        "end_column": 26,
        "function": "<module>",
        "source_line": "import nonexistent_module"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 1, in <module>\n    import nonexistent_module\nModuleNotFoundError: No module named 'nonexistent_module'",
      "type-msg": "ModuleNotFoundError: No module named 'nonexistent_module'",
      "msg": "No module named 'nonexistent_module'",
      "str": "ModuleNotFoundError: No module named 'nonexistent_module'",
      "exception": {
       "type": "ModuleNotFoundError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "No module named 'nonexistent_module'"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "t05_json_uncaught",
   "code": "import json\njson.loads('{\"a\": 1,\\n \"b\": }')",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "json.JSONDecodeError",
      "message": "Expecting value: line 2 column 7 (char 15)",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 1,
        "end_line": 2,
        "end_column": 32,
        "function": "<module>",
        "source_line": "json.loads('{\"a\": 1,\\n \"b\": }')"
       }
      ],
      "data": {
       "kind": "json",
       "msg": "Expecting value",
       "doc": "{\"a\": 1,\n \"b\": }",
       "pos": 15,
       "lineno": 2,
       "colno": 7
      }
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 2, in <module>\n    json.loads('{\"a\": 1,\\n \"b\": }')\n    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\njson.JSONDecodeError: Expecting value: line 2 column 7 (char 15)",
      "type-msg": "json.JSONDecodeError: Expecting value: line 2 column 7 (char 15)",
      "msg": "Expecting value: line 2 column 7 (char 15)",
      "str": "json.JSONDecodeError: Expecting value: line 2 column 7 (char 15)",
      "exception": {
       "type": "JSONDecodeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "Expecting value: line 2 column 7 (char 15)"
         }
        ]
       }
      },
      "data": {
       "kind": "json",
       "msg": "Expecting value",
       "doc": "{\"a\": 1,\n \"b\": }",
       "pos": 15,
       "lineno": 2,
       "colno": 7
      },
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "t04_unicode_attrs",
   "code": "try:\n    b\"ab\\xff\".decode(\"utf-8\")\nexcept UnicodeDecodeError as e:\n    r = (e.encoding, e.start, e.end, e.reason)\nr",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "AttributeError",
      "message": "'UnicodeDecodeError' object has no attribute 'encoding'",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 38,
        "end_line": 4,
        "end_column": 46,
        "function": "<module>",
        "source_line": "    r = (e.encoding, e.start, e.end, e.reason)"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 4, in <module>\n    r = (e.encoding, e.start, e.end, e.reason)\nAttributeError: 'UnicodeDecodeError' object has no attribute 'encoding'",
      "type-msg": "AttributeError: 'UnicodeDecodeError' object has no attribute 'encoding'",
      "msg": "'UnicodeDecodeError' object has no attribute 'encoding'",
      "str": "AttributeError: 'UnicodeDecodeError' object has no attribute 'encoding'",
      "exception": {
       "type": "AttributeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "'UnicodeDecodeError' object has no attribute 'encoding'"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "very_long_exception_message",
   "code": "raise ValueError('x' * 400)",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 7,
        "end_line": 1,
        "end_column": 28,
        "function": "<module>",
        "source_line": "raise ValueError('x' * 400)"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 1, in <module>\n    raise ValueError('x' * 400)\nValueError: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "type-msg": "ValueError: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "msg": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "str": "ValueError: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "unicode_exception_message",
   "code": "raise ValueError('日本語 🧪 café — αβγ')",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "日本語 🧪 café — αβγ",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 7,
        "end_line": 1,
        "end_column": 37,
        "function": "<module>",
        "source_line": "raise ValueError('日本語 🧪 café — αβγ')"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 1, in <module>\n    raise ValueError('日本語 🧪 café — αβγ')\nValueError: 日本語 🧪 café — αβγ",
      "type-msg": "ValueError: 日本語 🧪 café — αβγ",
      "msg": "日本語 🧪 café — αβγ",
      "str": "ValueError: 日本語 🧪 café — αβγ",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "日本語 🧪 café — αβγ"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "t03_unicode_uncaught",
   "code": "b\"ab\\xff\".decode(\"utf-8\")",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "UnicodeDecodeError",
      "message": "'utf-8' codec can't decode byte 0xff in position 2: invalid start byte",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 1,
        "column": 1,
        "end_line": 1,
        "end_column": 26,
        "function": "<module>",
        "source_line": "b\"ab\\xff\".decode(\"utf-8\")"
       }
      ],
      "data": {
       "kind": "unicode",
       "encoding": "utf-8",
       "object": {
        "t": "bytes",
        "hex": "6162ff"
       },
       "start": 2,
       "end": 3,
       "reason": "invalid start byte"
      }
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 1, in <module>\n    b\"ab\\xff\".decode(\"utf-8\")\n    ~~~~~~~~~~~~~~~~~~~~~~~~~\nUnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in position 2: invalid start byte",
      "type-msg": "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in position 2: invalid start byte",
      "msg": "'utf-8' codec can't decode byte 0xff in position 2: invalid start byte",
      "str": "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in position 2: invalid start byte",
      "exception": {
       "type": "UnicodeDecodeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "utf-8"
         },
         {
          "t": "bytes",
          "hex": "6162ff"
         },
         {
          "t": "int",
          "v": "2"
         },
         {
          "t": "int",
          "v": "3"
         },
         {
          "t": "str",
          "v": "invalid start byte"
         }
        ]
       }
      },
      "data": {
       "kind": "unicode",
       "encoding": "utf-8",
       "object": {
        "t": "bytes",
        "hex": "6162ff"
       },
       "start": 2,
       "end": 3,
       "reason": "invalid start byte"
      },
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "07_print_before_exception_single_feed",
   "code": "def work():\n    print('alpha')\n    print('beta', end='...')\n    print('gamma')\n    raise RuntimeError('failed after prints')\n\nwork()",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "RuntimeError",
      "message": "failed after prints",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 7,
        "column": 1,
        "end_line": 7,
        "end_column": 7,
        "function": "<module>",
        "source_line": "work()"
       },
       {
        "filename": "<python-input-0>",
        "line": 5,
        "column": 11,
        "end_line": 5,
        "end_column": 46,
        "function": "work",
        "source_line": "    raise RuntimeError('failed after prints')"
       }
      ]
     },
     "prints": [
      {
       "stream": "stdout",
       "text": "alpha\nbeta...gamma\n"
      }
     ],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 7, in <module>\n    work()\n    ~~~~~~\n  File \"<python-input-0>\", line 5, in work\n    raise RuntimeError('failed after prints')\nRuntimeError: failed after prints",
      "type-msg": "RuntimeError: failed after prints",
      "msg": "failed after prints",
      "str": "RuntimeError: failed after prints",
      "exception": {
       "type": "RuntimeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "failed after prints"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "08_print_error_then_recovery",
   "feeds": [
    "events = ['init']\n'feed1-ready'",
    "events.append('feed2-mutated')\nprint('feed2-before-boom')\nraise ValueError('feed2-boom')",
    "print('feed3-saw:', events)\nevents"
   ],
   "expected": [
    {
     "value": {
      "t": "str",
      "v": "feed1-ready"
     },
     "exception": null,
     "prints": [],
     "ext_calls": [],
     "error_class": null,
     "display": null
    },
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "feed2-boom",
      "traceback": [
       {
        "filename": "<python-input-1>",
        "line": 3,
        "column": 7,
        "end_line": 3,
        "end_column": 31,
        "function": "<module>",
        "source_line": "raise ValueError('feed2-boom')"
       }
      ]
     },
     "prints": [
      {
       "stream": "stdout",
       "text": "feed2-before-boom\n"
      }
     ],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-1>\", line 3, in <module>\n    raise ValueError('feed2-boom')\nValueError: feed2-boom",
      "type-msg": "ValueError: feed2-boom",
      "msg": "feed2-boom",
      "str": "ValueError: feed2-boom",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "feed2-boom"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    },
    {
     "value": {
      "t": "list",
      "items": [
       {
        "t": "str",
        "v": "init"
       },
       {
        "t": "str",
        "v": "feed2-mutated"
       }
      ]
     },
     "exception": null,
     "prints": [
      {
       "stream": "stdout",
       "text": "feed3-saw: ['init', 'feed2-mutated']\n"
      }
     ],
     "ext_calls": [],
     "error_class": null,
     "display": null
    }
   ]
  },
  {
   "id": "t02_host_raise_subclass",
   "code": "out = []\ntry:\n    f()\nexcept LookupError as e:\n    out.append(type(e).__name__)\ntry:\n    f()\nexcept ValueError as e:\n    out.append(type(e).__name__)\nout",
   "externals": {
    "f": [
     {
      "raise": {
       "type": "KeyError",
       "message": "k"
      }
     },
     {
      "raise": {
       "type": "json.JSONDecodeError",
       "message": "bad"
      }
     }
    ]
   },
   "expected": [
    {
     "value": {
      "t": "list",
      "items": [
       {
        "t": "str",
        "v": "KeyError"
       },
       {
        "t": "str",
        "v": "JSONDecodeError"
       }
      ]
     },
     "exception": null,
     "prints": [],
     "ext_calls": [
      {
       "name": "f",
       "args": [],
       "kwargs": {}
      },
      {
       "name": "f",
       "args": [],
       "kwargs": {}
      }
     ],
     "error_class": null,
     "display": null
    }
   ]
  },
  {
   "id": "t01_except_hierarchy",
   "code": "import json\nres = []\ntry:\n    {}[\"k\"]\nexcept LookupError as ex:\n    res.append(type(ex).__name__)\ntry:\n    1/0\nexcept ArithmeticError as ex:\n    res.append(type(ex).__name__)\ntry:\n    int(\"x\")\nexcept ValueError as ex:\n    res.append(type(ex).__name__)\ntry:\n    b\"\\xff\".decode(\"utf-8\")\nexcept ValueError as ex:\n    res.append(type(ex).__name__)\ntry:\n    json.loads(\"{\")\nexcept ValueError as ex:\n    res.append(type(ex).__name__)\ntry:\n    [][1]\nexcept LookupError as ex:\n    res.append(type(ex).__name__)\ntry:\n    undefined_name\nexcept Exception as ex:\n    res.append(type(ex).__name__)\nres",
   "expected": [
    {
     "value": {
      "t": "list",
      "items": [
       {
        "t": "str",
        "v": "KeyError"
       },
       {
        "t": "str",
        "v": "ZeroDivisionError"
       },
       {
        "t": "str",
        "v": "ValueError"
       },
       {
        "t": "str",
        "v": "UnicodeDecodeError"
       },
       {
        "t": "str",
        "v": "JSONDecodeError"
       },
       {
        "t": "str",
        "v": "IndexError"
       },
       {
        "t": "str",
        "v": "NameError"
       }
      ]
     },
     "exception": null,
     "prints": [],
     "ext_calls": [],
     "error_class": null,
     "display": null
    }
   ]
  },
  {
   "id": "typeerror_in_try_unmatched",
   "code": "def f():\n    return 1\ntry:\n    a = 1\n    b = f()()\n    print(b)\nexcept ValueError as e:\n    print(\"handled\")\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "TypeError",
      "message": "'int' object is not callable",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 8,
        "column": 5,
        "end_line": 8,
        "end_column": 21,
        "function": "<module>",
        "source_line": "    print(\"handled\")"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 8, in <module>\n    print(\"handled\")\nTypeError: 'int' object is not callable",
      "type-msg": "TypeError: 'int' object is not callable",
      "msg": "'int' object is not callable",
      "str": "TypeError: 'int' object is not callable",
      "exception": {
       "type": "TypeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "'int' object is not callable"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "shadow_in_loop_in_try",
   "code": "def g(n):\n    return [n]\ntry:\n    for i in range(2):\n        g = g(i)\nexcept ValueError:\n    print(\"handled\")\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "TypeError",
      "message": "'list' object is not callable",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 7,
        "column": 5,
        "end_line": 7,
        "end_column": 21,
        "function": "<module>",
        "source_line": "    print(\"handled\")"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 7, in <module>\n    print(\"handled\")\nTypeError: 'list' object is not callable",
      "type-msg": "TypeError: 'list' object is not callable",
      "msg": "'list' object is not callable",
      "str": "TypeError: 'list' object is not callable",
      "exception": {
       "type": "TypeError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "'list' object is not callable"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "14_limit_recursion_after_print",
   "code": "def climb(n):\n    if n in (0, 5):\n        print(f'at={n}')\n    return 1 + climb(n + 1)\n\nprint('begin-rec')\nclimb(0)",
   "limits": {
    "max_recursion_depth": 15
   },
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "RecursionError",
      "message": "maximum recursion depth exceeded",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 7,
        "column": 1,
        "end_line": 7,
        "end_column": 9,
        "function": "<module>",
        "source_line": "climb(0)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 16,
        "end_line": 4,
        "end_column": 28,
        "function": "climb",
        "source_line": "    return 1 + climb(n + 1)"
       },
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 8,
        "end_line": 2,
        "end_column": 19,
        "function": "climb",
        "source_line": "    if n in (0, 5):"
       }
      ]
     },
     "prints": [
      {
       "stream": "stdout",
       "text": "begin-rec\nat=0\nat=5\n"
      }
     ],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 7, in <module>\n    climb(0)\n    ~~~~~~~~\n  File \"<python-input-0>\", line 4, in climb\n    return 1 + climb(n + 1)\n               ~~~~~~~~~~~~\n  File \"<python-input-0>\", line 4, in climb\n    return 1 + climb(n + 1)\n               ~~~~~~~~~~~~\n  File \"<python-input-0>\", line 4, in climb\n    return 1 + climb(n + 1)\n               ~~~~~~~~~~~~\n  [Previous line repeated 11 more times]\n  File \"<python-input-0>\", line 2, in climb\n    if n in (0, 5):\n       ~~~~~~~~~~~\nRecursionError: maximum recursion depth exceeded",
      "type-msg": "RecursionError: maximum recursion depth exceeded",
      "msg": "maximum recursion depth exceeded",
      "str": "RecursionError: maximum recursion depth exceeded",
      "exception": {
       "type": "RecursionError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "maximum recursion depth exceeded"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "16_limit_memory_after_print",
   "code": "print('alloc-stage-1')\nbuf = ['ok']\nprint('alloc-stage-2', buf[0])\nbig = 'x' * 50000000\nlen(big)",
   "limits": {
    "max_memory": 1048576
   },
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "MemoryError",
      "message": "memory limit exceeded: N bytes > N bytes",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 7,
        "end_line": 4,
        "end_column": 21,
        "function": "<module>",
        "source_line": "big = 'x' * 50000000"
       }
      ]
     },
     "prints": [
      {
       "stream": "stdout",
       "text": "alloc-stage-1\nalloc-stage-2 ok\n"
      }
     ],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-N>\", line N, in <module>\n    big = 'x' * N\n          ~~~~~~~~~~~~~~\nMemoryError: memory limit exceeded: N bytes > N bytes",
      "type-msg": "MemoryError: memory limit exceeded: N bytes > N bytes",
      "msg": "memory limit exceeded: N bytes > N bytes",
      "str": "MemoryError: memory limit exceeded: N bytes > N bytes",
      "exception": {
       "type": "MemoryError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "memory limit exceeded: N bytes > N bytes"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ],
   "normalize_numbers": true
  },
  {
   "id": "parser_unsupported_inheritance",
   "code": "class Base:\n    pass\n\nclass Child(Base):\n    pass",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "NotImplementedError",
      "message": "The monty syntax parser does not yet support class inheritance and metaclasses",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 1,
        "end_line": 5,
        "end_column": 9,
        "function": null,
        "source_line": "class Child(Base):\n    pass"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 4, in <module>\n    class Child(Base):\n        pass\nNotImplementedError: The monty syntax parser does not yet support class inheritance and metaclasses",
      "type-msg": "NotImplementedError: The monty syntax parser does not yet support class inheritance and metaclasses",
      "msg": "The monty syntax parser does not yet support class inheritance and metaclasses",
      "str": "NotImplementedError: The monty syntax parser does not yet support class inheritance and metaclasses",
      "exception": {
       "type": "NotImplementedError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "The monty syntax parser does not yet support class inheritance and metaclasses"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "parser_unsupported_yield",
   "code": "def values():\n    yield 1\n\nvalues()",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "NotImplementedError",
      "message": "The monty syntax parser does not yet support yield expressions",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 5,
        "end_line": 2,
        "end_column": 12,
        "function": null,
        "source_line": "    yield 1"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 2, in <module>\n    yield 1\n    ~~~~~~~\nNotImplementedError: The monty syntax parser does not yet support yield expressions",
      "type-msg": "NotImplementedError: The monty syntax parser does not yet support yield expressions",
      "msg": "The monty syntax parser does not yet support yield expressions",
      "str": "NotImplementedError: The monty syntax parser does not yet support yield expressions",
      "exception": {
       "type": "NotImplementedError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "The monty syntax parser does not yet support yield expressions"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "17_very_long_source_line_frame",
   "code": "def long_line_lookup(d):\n    return (1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + 14 + 15 + 16 + 17 + 18 + 19 + 20 + 21 + 22 + 23 + 24 + 25 + 26 + 27 + 28 + 29 + 30 + 31 + 32 + 33 + 34 + 35 + 36 + 37 + 38 + 39 + 40 + 41 + 42 + 43 + 44 + 45 + 46 + 47 + 48 + 49 + 50 + 51 + 52 + 53 + 54 + 55 + 56 + 57 + 58 + 59 + 60 + 61 + 62 + 63 + 64 + 65 + 66 + 67 + 68 + 69 + 70 + d['missing_key_at_end_of_very_long_line'])\n\nlong_line_lookup({})",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "KeyError",
      "message": "missing_key_at_end_of_very_long_line",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 4,
        "column": 1,
        "end_line": 4,
        "end_column": 21,
        "function": "<module>",
        "source_line": "long_line_lookup({})"
       },
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 354,
        "end_line": 2,
        "end_column": 395,
        "function": "long_line_lookup",
        "source_line": "    return (1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + 14 + 15 + 16 + 17 + 18 + 19 + 20 + 21 + 22 + 23 + 24 + 25 + 26 + 27 + 28 + 29 + 30 + 31 + 32 + 33 + 34 + 35 + 36 + 37 + 38 + 39 + 40 + 41 + 42 + 43 + 44 + 45 + 46 + 47 + 48 + 49 + 50 + 51 + 52 + 53 + 54 + 55 + 56 + 57 + 58 + 59 + 60 + 61 + 62 + 63 + 64 + 65 + 66 + 67 + 68 + 69 + 70 + d['missing_key_at_end_of_very_long_line'])"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 4, in <module>\n    long_line_lookup({})\n    ~~~~~~~~~~~~~~~~~~~~\n  File \"<python-input-0>\", line 2, in long_line_lookup\n    return (1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + 14 + 15 + 16 + 17 + 18 + 19 + 20 + 21 + 22 + 23 + 24 + 25 + 26 + 27 + 28 + 29 + 30 + 31 + 32 + 33 + 34 + 35 + 36 + 37 + 38 + 39 + 40 + 41 + 42 + 43 + 44 + 45 + 46 + 47 + 48 + 49 + 50 + 51 + 52 + 53 + 54 + 55 + 56 + 57 + 58 + 59 + 60 + 61 + 62 + 63 + 64 + 65 + 66 + 67 + 68 + 69 + 70 + d['missing_key_at_end_of_very_long_line'])\n                                                                                                                                                                                                                                                                                                                                                                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\nKeyError: missing_key_at_end_of_very_long_line",
      "type-msg": "KeyError: missing_key_at_end_of_very_long_line",
      "msg": "missing_key_at_end_of_very_long_line",
      "str": "KeyError: missing_key_at_end_of_very_long_line",
      "exception": {
       "type": "KeyError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "missing_key_at_end_of_very_long_line"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "b12_dict__subscript_missing_key",
   "code": "d = {'a': 1}\nd['missing']\n# Raise=KeyError('missing')\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "KeyError",
      "message": "missing",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 1,
        "end_line": 2,
        "end_column": 13,
        "function": "<module>",
        "source_line": "d['missing']"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 2, in <module>\n    d['missing']\n    ~~~~~~~~~~~~\nKeyError: missing",
      "type-msg": "KeyError: missing",
      "msg": "missing",
      "str": "KeyError: missing",
      "exception": {
       "type": "KeyError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "missing"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "b12_with__cm_nested_body_raises_traceback",
   "code": "# Nested `with` blocks with a passthrough class cm at each level: an\n# exception raised in the innermost body propagates through both\n# `__exit__` calls (both return None) and surfaces with the body's frame\n# intact. Verifies that `WithExceptStart` doesn't perturb the propagating\n# exception's traceback when `__exit__` is a no-op cleanup.\nclass CM:\n    def __enter__(self):\n        return self\n\n    def __exit__(self, typ, val, tb):\n        return None\n\n\nwith CM() as outer:\n    with CM() as inner:\n        raise ValueError('from inner body')\n\"\"\"\nTRACEBACK:\nTraceback (most recent call last):\n  File \"with__cm_nested_body_raises_traceback.py\", line 16, in <module>\n    raise ValueError('from inner body')\nValueError: from inner body\n\"\"\"\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "from inner body",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 16,
        "column": 15,
        "end_line": 16,
        "end_column": 44,
        "function": "<module>",
        "source_line": "        raise ValueError('from inner body')"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 16, in <module>\n    raise ValueError('from inner body')\nValueError: from inner body",
      "type-msg": "ValueError: from inner body",
      "msg": "from inner body",
      "str": "ValueError: from inner body",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "from inner body"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "09_repl_feed2_feed3_traceback_frames",
   "feeds": [
    "def base_div(x):\n    return 100 // x\n'feed1-ready'",
    "def mid_call(y):\n    return base_div(y) + 1\n\nmid_call(0)",
    "def top_lookup(mapping):\n    return mapping['absent_in_feed3']\n\ntop_lookup({'a': 1})"
   ],
   "expected": [
    {
     "value": {
      "t": "str",
      "v": "feed1-ready"
     },
     "exception": null,
     "prints": [],
     "ext_calls": [],
     "error_class": null,
     "display": null
    },
    {
     "value": null,
     "exception": {
      "type": "ZeroDivisionError",
      "message": "division by zero",
      "traceback": [
       {
        "filename": "<python-input-1>",
        "line": 4,
        "column": 1,
        "end_line": 4,
        "end_column": 12,
        "function": "<module>",
        "source_line": "mid_call(0)"
       },
       {
        "filename": "<python-input-1>",
        "line": 2,
        "column": 12,
        "end_line": 2,
        "end_column": 23,
        "function": "mid_call",
        "source_line": "    return base_div(y) + 1"
       },
       {
        "filename": "<python-input-0>",
        "line": 2,
        "column": 12,
        "end_line": 2,
        "end_column": 20,
        "function": "base_div",
        "source_line": "    return 100 // x"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-1>\", line 4, in <module>\n    mid_call(0)\n    ~~~~~~~~~~~\n  File \"<python-input-1>\", line 2, in mid_call\n    return base_div(y) + 1\n           ~~~~~~~~~~~\n  File \"<python-input-0>\", line 2, in base_div\n    return 100 // x\n           ~~~~~~~~\nZeroDivisionError: division by zero",
      "type-msg": "ZeroDivisionError: division by zero",
      "msg": "division by zero",
      "str": "ZeroDivisionError: division by zero",
      "exception": {
       "type": "ZeroDivisionError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "division by zero"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    },
    {
     "value": null,
     "exception": {
      "type": "KeyError",
      "message": "absent_in_feed3",
      "traceback": [
       {
        "filename": "<python-input-2>",
        "line": 4,
        "column": 1,
        "end_line": 4,
        "end_column": 21,
        "function": "<module>",
        "source_line": "top_lookup({'a': 1})"
       },
       {
        "filename": "<python-input-2>",
        "line": 2,
        "column": 12,
        "end_line": 2,
        "end_column": 38,
        "function": "top_lookup",
        "source_line": "    return mapping['absent_in_feed3']"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-2>\", line 4, in <module>\n    top_lookup({'a': 1})\n    ~~~~~~~~~~~~~~~~~~~~\n  File \"<python-input-2>\", line 2, in top_lookup\n    return mapping['absent_in_feed3']\n           ~~~~~~~~~~~~~~~~~~~~~~~~~~\nKeyError: absent_in_feed3",
      "type-msg": "KeyError: absent_in_feed3",
      "msg": "absent_in_feed3",
      "str": "KeyError: absent_in_feed3",
      "exception": {
       "type": "KeyError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "absent_in_feed3"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  },
  {
   "id": "b12_class__method_raises",
   "code": "class Account:\n    def __init__(self, balance: int) -> None:\n        self.balance = balance\n\n    def withdraw(self, amount: int) -> None:\n        if amount > self.balance:\n            raise ValueError('insufficient funds')\n        self.balance -= amount\n\n\na = Account(100)\na.withdraw(200)\n\"\"\"\nTRACEBACK:\nTraceback (most recent call last):\n  File \"class__method_raises.py\", line 12, in <module>\n    a.withdraw(200)\n    ~~~~~~~~~~~~~~~\n  File \"class__method_raises.py\", line 7, in withdraw\n    raise ValueError('insufficient funds')\nValueError: insufficient funds\n\"\"\"\n",
   "expected": [
    {
     "value": null,
     "exception": {
      "type": "ValueError",
      "message": "insufficient funds",
      "traceback": [
       {
        "filename": "<python-input-0>",
        "line": 12,
        "column": 1,
        "end_line": 12,
        "end_column": 16,
        "function": "<module>",
        "source_line": "a.withdraw(200)"
       },
       {
        "filename": "<python-input-0>",
        "line": 7,
        "column": 19,
        "end_line": 7,
        "end_column": 51,
        "function": "withdraw",
        "source_line": "            raise ValueError('insufficient funds')"
       }
      ]
     },
     "prints": [],
     "ext_calls": [],
     "error_class": "MontyRuntimeError",
     "display": {
      "traceback": "Traceback (most recent call last):\n  File \"<python-input-0>\", line 12, in <module>\n    a.withdraw(200)\n    ~~~~~~~~~~~~~~~\n  File \"<python-input-0>\", line 7, in withdraw\n    raise ValueError('insufficient funds')\nValueError: insufficient funds",
      "type-msg": "ValueError: insufficient funds",
      "msg": "insufficient funds",
      "str": "ValueError: insufficient funds",
      "exception": {
       "type": "ValueError",
       "args": {
        "t": "tuple",
        "items": [
         {
          "t": "str",
          "v": "insufficient funds"
         }
        ]
       }
      },
      "data": null,
      "bad_format": {
       "format": "nope",
       "type": "ValueError",
       "message": "Invalid display format: 'nope'. Expected 'traceback', 'type-msg', or 'msg'"
      }
     }
    }
   ]
  }
 ]
}
''';
