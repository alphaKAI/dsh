module dsh.commandLine;

import dsh.executeMachine,
       dsh.environment,
       dsh.shellScript,
       dsh.users,
       dsh.user;

import std.algorithm.searching,
       std.algorithm.iteration,
       std.process,
       std.string,
       std.array,
       std.regex,
       std.stdio,
       std.file,
       std.conv;

import core.sys.posix.signal,
       core.stdc.signal,
       core.stdc.string,
       core.stdc.stdlib,
       core.memory;

import parser.parser,
       ir.analysis,
       runtime.vm,util.string,
       util.os,
       options,
       ir.ir;

enum DSHMode : int {
  user,
  root
}

IRInstr instrPtr = null;

extern (C) void segfaultHandler(int signal, siginfo_t* si, void* arg) {
    import jit.codeblock;

    // si->si_addr is the instruction pointer
    auto ip = cast(CodePtr)si.si_addr;

    writeln();
    writeln("Caught segmentation fault");
    writeln("IP=", ip);

    auto cb = vm.execHeap;
    auto startAddr = cb.getAddress(0);
    auto endAddr = startAddr + cb.getWritePos();

    if (ip >= startAddr && ip < endAddr)
    {
      auto offset = ip - startAddr;
      writeln("IP in jitted code, offset=", offset);
    }

    if (vm.curInstr !is null)
    {
      writeln("vm.curInstr: ", vm.curInstr);
    }

    if (instrPtr !is null)
    {
      writeln("instrPtr: ", instrPtr);
      writeln("curFun: ", instrPtr.block.fun.getName);
    }

    writeln("exiting");
    exit(139);
  }
immutable EXITDSH    = -0xdeadbeaf;

class DSHCommandLine {
  private DSHMode currentMode;
  private DSHUser user;
  private DSHUsers users;
  private ExecuteMachine EM;
  private DSHshellScript shellScript;
  private string hostName;
  private string pluginDir;
  private string[] commands;

  this(string[] args) {
    currentMode = DSHMode.user;
    user  = new DSHUser(0, environment.get("USER"));
    users = new DSHUsers(user);
    EM    = new ExecuteMachine;
    hostName = "MacBook-Pro";//environment.get("HOST");
    shellScript = new DSHshellScript(
                    EM,
                    users.currentUser.env);
    commands = [
      "exit", "sudo", "ls", "cd", "pwd", "help", "users", 
      "login", "createuser", "aliases",
      "alias", "unalias", "saveConfig",
      "set", "unset", "default"];


    EM.registerEventByHash([
      "exit" : EMEvent("exit", "^exit", (string[] arguments, string inputLine) {
          if (users.exit) {
            if (users.nestedLogin) {
              users.logout;
              return EM_SUCCESS;
            } else {
              return EXITDSH;
            }
          } else {
            return EM_FAILURE;
          }
        }),
      "ls" : EMEvent("ls", "^ls", (string[] arguments, string inputLine) {
          bool allFlag,
               listFlag;

          allFlag  = ["-a", "-al","-la"].any!(x => inputLine.canFind(x));
          listFlag = ["-l", "-al","-la"].any!(x => inputLine.canFind(x));

          if (allFlag || listFlag) {
            arguments = arguments.filter!(x => !["", "-a", "-l", "-al", "-la"].canFind(x)).array;
              if (arguments.length == 1) {}
            }

          if (arguments.length < 2) {
            arguments ~= "";
          }

          if (arguments[1].empty) {
            arguments[1] = getcwd;
          }

          if (!std.file.exists(arguments[1])) {
            writeln("Doesn't foind such a directory - ", arguments[1]);

            return EM_FAILURE;
          } else {
            foreach(e; dirEntries(arguments[1], SpanMode.shallow)) {
              if (!allFlag) {
                if (e.name.matchAll(regex(r"^\."))) {
                  continue;
                }
              }

              if (listFlag) {
                writeln(e);
              } else {
                std.stdio.write(e, " ");
              }
            }
            return EM_SUCCESS;
          }
        }),
      "cd" : EMEvent("cd", "^cd", (string[] arguments, string inputLine) {
          if (arguments.length < 2) {
            arguments ~= getcwd;
          }

          if (!std.file.exists(arguments[1]) || (std.file.exists(arguments[1]) && !isDir(arguments[1]))) {
            writeln("Doesn't foind such a directory - ", arguments[1]);

            return EM_FAILURE;
          } else {
            arguments[0].chdir;

            return EM_SUCCESS;
          }
        }),
      "pwd" : EMEvent("pwd", "^pwd", (string[] arguments, string inputLine) {
            writeln(getcwd);

            return EM_SUCCESS;
          }),
      "help" : EMEvent("help", "^help", (string[] arguments, string inputLine) {
            writeln("commands:");

            foreach (command; commands) {
              writeln("  ", command);
            }

            return EM_SUCCESS;
          }),
      "sudo" : EMEvent("sudo", "^sudo", (string[] arguments, string inputLine) {
            if (arguments.length < 2) {
              writeln("[Error - sudo]");
              writeln("Wrong arguments. Sudo require two arguments.");

              return EM_FAILURE;
            } else {
              users.currentUser.suMode;
              processLine(arguments[1..$].join(" "));
              users.currentUser.exit;

              return EM_SUCCESS;
            }
          }),
      "suMode" : EMEvent("suMode", "^suMode", (string[] arguments, string inputLine) {
            if (users.currentUser.suMode) {
              return EM_SUCCESS;
            } else {
              return EM_FAILURE;
            }
          }),
      "users" : EMEvent("users", "^users", (string[] arguments, string inputLine) {
            foreach (_user; users.users) {
              writeln(_user);
            }

            return EM_SUCCESS;
          }),
      "login" : EMEvent("login", "^login", (string[] arguments, string inputLine) {
            if (arguments.length < 2) {
              writeln("[Wrong arguments] - Require two arguments");

              return EM_FAILURE;
            }

            if (users.login(arguments[1])) {
              return EM_SUCCESS;
            } else {
              return EM_FAILURE;
            }
          }),
      "createuser" : EMEvent("createuser", "^createuser", (string[] arguments, string inputLine) {
            if (arguments.length < 2) {
              writeln("[Wrong arguments] - Require two arguments");

              return EM_FAILURE;
            }

            string userName = arguments[1];

            if (userName == string.init) {
              writeln("Empty user name is not allowed");

              return EM_FAILURE;
            } else {
              users.addUser(userName);

              return EM_SUCCESS;
            }
          }),
      "aliases" : EMEvent("aliases", "^aliases", (string[] arguments, string inputLine) {
            foreach (_short, _long; users.currentUser.aliases) {
              writeln(_short, " -> ", _long);
            }

            return EM_SUCCESS;
          }),
      "alias" : EMEvent("alias", "^alias$", (string[] arguments, string inputLine) {
            inputLine = inputLine.replace("alias ", "");

            if (!inputLine.canFind("=")) {
              writeln("[Error -> Failed to add alias] : Your foramt is wrong");

              return EM_FAILURE;
            } else {
              writeln("[Add alias] : ",inputLine.split("=")[0].strip, " => ", inputLine.split("=")[1..$].join("=").strip);
              users.currentUser.addAlias([
                "contracted" : inputLine.split("=")[0].strip,
                "expanded"   : inputLine.split("=")[1..$].join("=").strip
              ]);
              
              return EM_SUCCESS;
            }
          }),
      "unalias" : EMEvent("unalias", "^unalias", (string[] arguments, string inputLine) {
            foreach (e; inputLine.split[1..$]) {
              users.currentUser.unalias(e);
            }

            return EM_SUCCESS;
          }),
      "saveConfig" : EMEvent("saveConfig", "^saveConfig", (string[] arguments, string inputLine) {
            users.currentUser.saveConfig;

            return EM_SUCCESS;
          }),
      "set" : EMEvent("set", "^set", (string[] arguments, string inputLine) {
            if (arguments.length < 2) {
              writeln("[Wrong arguments] - Require two arguments");

              return EM_FAILURE;
            }

            string argumentsLine = arguments[1..$].join;
            users.currentUser.env.setEnv(argumentsLine.split("=")[0], argumentsLine.split("=")[1]);

            return EM_SUCCESS;
          }),
      "unset" : EMEvent("unset", "^unset", (string[] arguments, string inputLine) {
            if (arguments.length < 2) {
              writeln("[Wrong arguments] - Require two arguments");

              return EM_FAILURE;
            }

             users.currentUser.env.deleteEnv(arguments[1]);

            return EM_SUCCESS;
          }),
      "default" : EMEvent("default", null, (string[] arguments, string inputLine) {
            if (std.file.exists(arguments[0]) && arguments[0].isDir) {
              arguments[0].chdir;

              return EM_SUCCESS;
            }

            if (arguments[0].matchAll(regex(r"^.\w+")) && inputLine[0].to!string == ".") {
              inputLine = inputLine[1..$];

              auto pid = spawnProcess(inputLine);
              auto status = wait(pid);
              if (status == 0) {
                return EM_SUCCESS;
              } else {
                return EM_FAILURE;
              }
            }

            /**/
            string inputBuffer = inputLine;
            
            while (!shellScript.tokenValidator(inputBuffer)) {
              write("blockInput => ");
              string input = readln;
              if (stdin.eof) {
                break;
              }
              inputBuffer ~= input.chomp;
            }

            try {
              vm.evalString(inputBuffer);
            } catch {
              writeln("Some Error");
            }

            return EM_SUCCESS;
          }),
    ]);


    initHiggsVM;
  }

  private void initHiggsVM() {
    GC.reserve(1024 * 1024 * 1024);

    sigaction_t sa;
    memset(&sa, 0, sa.sizeof);
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = &segfaultHandler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, null);


    VM.init(!opts.noruntime, !opts.nostdlib);
  }

  ~this() {
    VM.free;
  }

  private void processLine(string inputLine) {
    string commandName;

    if (!inputLine.replace(" ", "").empty) {
      commandName = replaceStringByTable(users.currentUser.aliases, inputLine.split[0], ["headFlag" : true]);
      inputLine   = ([commandName] ~ inputLine.split[1..$]).join(" ");
    }

    bool pipeFlag = false;
    string[] lineCommands;
    int indexOfCommands;

    foreach (arg; inputLine.split) {
      if (arg == "|") {
        pipeFlag = true;
        indexOfCommands++;

        continue;
      } else if (arg == "&&" || arg == ";") {
        indexOfCommands++;

        continue;
      }

      lineCommands.length++;
      if (lineCommands[indexOfCommands] == null) {
        lineCommands[indexOfCommands] = arg ~ " ";
      } else {
        lineCommands[indexOfCommands] ~= (arg ~ " ");
      }
    }

    Pipe[] pipes;//[rr, ww]
    File[] pipeios;
    File _stdin  = stdin,
         _stdout = stdout;

    if (pipeFlag) {
      pipes.length = (lineCommands.length - 1);
      pipeios = [stdin] ~ pipes.map!(pipe => [pipe.writeEnd, pipe.readEnd]).join  ~ [stdout];
    }

    foreach (command; lineCommands.filter!(x => x != "")) {
      File rr,
           ww;

      if (pipeFlag) {
        if (0 < pipeios.length) {
          rr = pipeios[0];
          ww = pipeios[1];
          _stdin  = rr;
          _stdout = ww;
          pipeios = pipeios[2..$];
        } else {
          _stdin  = stdin;
          _stdout = stdout;
        }
      }

      inputLine = command;
      inputLine = inputLine.replace("~/", environment.get("HOME") ~ "/");
      bool redirectFlag = false;

      string[] dontReplaceEnvCommandNames = ["set", "unset"];
      if (!dontReplaceEnvCommandNames.canFind(inputLine.split[0])) {
        inputLine = users.currentUser.env.replaceEnvs(inputLine);
      }

      if (inputLine.matchAll(regex(r".*\s>(.*)"))) {
        string fname = inputLine.split(">")[1].strip;
        _stdout = File(fname, "w");
        inputLine = inputLine.replace(regex(r"\s?>.*"), "");
        redirectFlag = true;
      }

      if (EXITDSH == EM.execute(inputLine)) {
        import std.c.stdlib : exit;
        writeln("Exit dsh");
        exit(0);
      }

      if (redirectFlag) {
        _stdout = stdout;
      }

      if (pipeFlag) {
        if (rr != stdin) {
          rr.close;
        }

        if (ww != stdout) {
          ww.close;
        }

        _stdin  = stdin;
        _stdout = stdout;
      }
    }
  }

  public void commandLine() {
    for (;;) {
      string prompt    = "\r\x1B[36m" ~ users.currentUser.name ~ "\x1B[0m\x1B[36m@" ~ hostName ~ "\x1B[0m \x1B[31m[dsh]\x1B[0m \x1B[1m" ~ pathCompress(getcwd) ~ "\x1B[0m " ~ getPrompt ~ " ";
      write(prompt);
      string inputLine = readln.chomp;
      if (stdin.eof) {
        inputLine = "exit";
      }

      processLine(inputLine);
    }
  }
  
  private string getPrompt() {
    return users.currentUser.isRoot ? "#" : "%";
  }

  private string replaceStringByTable(string[string] table, string target, bool[string] flags = null) {
    string returnString = target;

    foreach (key, _value; table) {
      string value = _value.replace("\"", "");
      Regex!char pattern;

      if (flags.keys.canFind("headFlag")) {
        if (flags["headFlag"]) {
          pattern = regex(key ~ "$");
        }
      } else {
        pattern = regex(key);
      }

      if (returnString.matchAll(pattern)) {
        returnString = returnString.replace(key, value);
      }
    }

    return returnString;
  }

  private string pathCompress(string path) {
    if (path.matchAll(environment.get("HOME"))) {
      path = path.replace(environment.get("HOME"), "~");
    }

    return path;
  }
}
