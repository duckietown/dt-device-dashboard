# Template: template-compose

This template provides a boilerplate repository for developing browser-based dashboards based on 
[\compose\](https://github.com/afdaniele/compose).


## How to use it

### 1. Fork this repository

Use the fork button in the top-right corner of the github page to fork this template repository.


### 2. Create a new repository

Create a new repository on github.com while
specifying the newly forked template repository as
a template for your new repository.


### 3. Define dependencies

List the dependencies in the files `dependencies-apt.txt` and
`dependencies-py3.txt` (apt packages and pip packages respectively).

List duckietown Python dependencies in the file `dependencies-py3.dt.txt`.

List \compose\ packages to install in the file `dependencies-compose.txt`.


### 4. Build and Run

Use the traditional devel tools to build and run this project.

#### Build

```shell
dts devel build
```

#### Run

```shell
dts devel run [options]
```
