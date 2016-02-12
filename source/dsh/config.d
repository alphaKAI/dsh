module dsh.config;

import std.algorithm.searching,
       std.variant;

enum ElementType : int {
  STRING,
  INTEGER,
  UINTEGER,
  FLOAT,
  ARRAY,
  OBJECT,
  NULL
}

class ConfigElement {
  private Variant _value;
  public ElementType _type;

  this(Variant newValue, ElementType type) {
    _value = newValue;
    _type = type;
  }

  @property Variant value() {
    return _value;
  }

  @property ElementType type() {
    return _type;
  }
}

class DSHConfig {
  private ConfigElement[string] config;

  public void addNewConfig(T)(T value, string key, ElementType type) {
    Variant _value = value;
    config[key] = new ConfigElement(_value, type);
  }

  public void clearConfig(string key) {
    config[key] = null;
  }

  public Variant getConfig(string key) {
    if (configExists(key)) {
      return config[key].value;
    } else {
      Variant v = "";
      return v;
    }
  }

  private bool configExists(string key) {
    return config.keys.canFind(key);
  }
}
/*
import std.stdio,
       std.json,
       std.file;
void main() {
  DSHConfig config = new DSHConfig;
  auto parsed = parseJSON(readText("alphakai.json"));
      foreach (key, value; parsed.object) {
        switch (value.type) {
          case JSON_TYPE.STRING:
            config.addNewConfig(value.str, key, ElementType.STRING);
            break;
          case JSON_TYPE.INTEGER:
            config.addNewConfig(value.integer, key, ElementType.INTEGER);
            break;
          case JSON_TYPE.UINTEGER:
            config.addNewConfig(value.uinteger, key, ElementType.UINTEGER);
            break;
          case JSON_TYPE.FLOAT:
            config.addNewConfig(value.floating, key, ElementType.FLOAT);
            break;
          case JSON_TYPE.ARRAY:
            config.addNewConfig(value.array, key, ElementType.ARRAY);
            break;
          case JSON_TYPE.OBJECT:
            Variant[string] hash;
            foreach (k, v; value.object) {
              hash[k] = v;
            }
            config.addNewConfig(hash, key, ElementType.OBJECT);
            break;
          case JSON_TYPE.NULL:
            config.addNewConfig(null, key, ElementType.NULL);
            break;

          default: break;
        }
      }
import std.conv;
(*config.getConfig("aliases").peek!(Variant[string])).to!(string[string].writeln;

    // create a json struct
    JSONValue jj = [ "language": "D" ];
    // rating doesnt exist yet, so use .object to assign
    jj.object["rating"] = JSONValue(3.14);
    // create an array to assign to list
    jj.object["list"] = JSONValue( ["a", "b", "c"] );
    // list already exists, so .object optional
    jj["list"].array ~= JSONValue("D");

    string s = jj.toString();
    writeln(s);
}
*/
