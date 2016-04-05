# nginx-combo
Documentation for my dockerized nginx and supporting containers. Boilerplate configuration for running 1 (or more) nginx containers with side containers for configuration. The goal is to make the type of configuration and work that would otherwise be simpler to just add to a single application server copy-pasteable into a new project so it can easily start out scaleable.

### Assumptions and Opinions
* Alpine Linux is my prefered containerized OS, and the choice I've made for nginix-combo containers
* CoreOS is the chosen host operating system
  * fleet comes for free for orchestration
  * etcd comes for free for a key value store

### Requirements and Features
* Forward's nginx logs to the docker service [loggly](https://www.loggly.com/blog/top-5-docker-logging-methods-to-fit-your-container-deployment-strategy/)
* Automatically reconfigures and refreshes based on routing configuration provided through etcd
* SSL termination
* Https certificate from letsencrypt with autorenewal
* By default forward http connections to https
  * Have a configuration mode which allows initial letsencrypt validation over http
* Oauth(2) Termination
  * JWT generation and validation

### Architecture
