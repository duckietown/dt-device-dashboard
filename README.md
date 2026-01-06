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