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

Use the traditional `dts devel` tools to build and run this project. Replace `[ROBOT_NAME]` with the name of your Duckiebot:

#### Build

```shell
dts devel build -H [ROBOT_NAME]
```

#### Run

```shell
dts devel run -H [ROBOT_NAME] --rm -- -e HTTP_PORT=8080 -v /data/ramdisk/dtps:/dtps -v /secrets:/secrets
```

### Build and Run the dashboard locally

You can also build and run the dashboard locally for development purposes.
#### Build

```shell
dts devel build
```

#### Run

```shell
cd sandbox && make run
```

This will start the dashboard and bind it to a Unix domain socket `/run/php/php7.4-fpm.sock`. Then it will also start `nginx` and bind it to port 80 inside the container. Port 80 is mapped to port 8888 on the host machine, so you can access the dashboard by navigating to `http://localhost:8888` in your web browser.

##### Using local versions of compose packages

To use local versions of \compose\ packages instead of the ones installed via the `dependencies-compose.txt` file, you can mount the local directories as volumes when running the container. For example, if you have a local copy of the `duckietown_duckiedrone` package, you can run:

```shell
make run EXTRA_ARGS='-v "${HOME}/Duckietown/ente/compose/compose-pkg-duckietown-duckiedrone:/user-data/packages/duckietown_duckiedrone:rw"'
```

This will mount the local `duckietown_duckiedrone` package into the container, allowing you to use your local changes without having to push to the remote repository.

Note that the package **must have been already installed** once via the `dependencies-compose.txt` file, as the package manager will not perform installation automatically when mounting local directories.