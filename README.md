# Zqlite

A small SQLite-inspired database written in Zig, built to learn database design and internals.

## About The Project

Zqlite is a personal project for learning database design and fundamentals. It is a simple file-backed database with a REPL, modeled after SQLite's storage ideas: a pager, B-tree, and a tiny SQL subset.

The implementation mainly follows [Let's Build a Simple Database](https://cstack.github.io/db_tutorial/).

Currently supported statements:

- `insert`
- `select`

## Getting Started

Clone the repo, build with Zig, and pass a database file path to the binary.

### Prerequisites

* [Zig 0.17](https://ziglang.org/download/)

```sh
zig version
```

### Installation

1. Clone the repo
   ```sh
   git clone https://github.com/AamerAijaz/Zqlite.git
   cd Zqlite
   ```
2. Build
   ```sh
   zig build
   ```
3. Run, passing a path to a database file (created if it does not exist)
   ```sh
   ./zig-out/bin/zqlite.exe <path-to-a-db-file>
   ```

On non-Windows platforms the binary is `./zig-out/bin/zqlite`.

## Usage

Zqlite opens a REPL. Rows have an integer `id`, a `username` (up to 32 bytes), and an `email` (up to 255 bytes).

```text
zqlite> insert 1 user1 user1@example.com
Executed.
zqlite> select
(1, user1, user1@example.com)
Executed.
zqlite> .exit
```

Meta commands start with `.`. `.exit` closes the connection and leaves the REPL.

Supported SQL today is only `insert` and `select`. There is no `update`, `delete`, or a fuller query language yet.

## Known Issues

- Out of order inserts are broken. Inserting rows whose ids are not strictly increasing does not work correctly.

## Acknowledgments

* [Let's Build a Simple Database](https://cstack.github.io/db_tutorial/)
* [Best-README-Template](https://github.com/othneildrew/Best-README-Template)
* [Zig](https://ziglang.org/)
