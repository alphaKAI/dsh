module dsh.executeMachine;

import std.algorithm.searching,
       std.algorithm.iteration,
       std.string,
       std.range,
       std.regex,
       std.stdio;

immutable EM_DEBUG = false;
immutable EM_SUCCESS = 0;
immutable EM_FAILURE = -1;

struct EMEvent {
  string eventName;
  string pattern;
  int delegate(string[], string) behave;
}

class ExecuteMachine {
  private string[] _regexes;
  private EMEvent[string] events;

  @property string[] regexes() {
    return _regexes;
  }

  public bool eventExists(string eventName) {
    return events.keys.canFind(eventName);
  }

  public void registerEvent(EMEvent event) {
    events[event.eventName] = event;

    _regexes ~= event.pattern;
  }

  public void registerEventByHash(EMEvent[string] eventHash) {
    foreach(eventName, event; eventHash) {
      registerEvent(event);
    }
  }

  public bool deleteEvent(string eventName) {
    if (eventExists(eventName) is false) {
      return false;
    } else {
      events.remove(eventName);
      return true;
    }
  }

  public int execute(string inputLine) {
    static if (EM_DEBUG) {  
      writeln("-> ExecuteMachine.execute");
      writeln("[EM.execute] -> inputLine : ", inputLine);
      writeln("[EM.execute] -> events : ", events);
    }
    
    string[] arguments;
    string eventName;

    foreach(event; events) {
      if (EM_DEBUG) {
        writeln("\x1B[32m REGEX -> ", event.pattern, "\x1B[0m");
      }

      if (event.pattern !is null && inputLine.matchAll(regex(event.pattern))) {
        if (EM_DEBUG) {
          writeln(event.eventName);
        }

        eventName = event.eventName;
        break;
      }
    }

    arguments = inputLine.split;
    if (eventName is null) {
      eventName = "default";
    }

    if (EM_DEBUG) {
      writeln("[EM.execute] -> eventName : ", eventName);
    }

    return events[eventName].behave(arguments, inputLine);
  }
}
