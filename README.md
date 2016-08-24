# web-application cluster boiler-plate
Documentation and copy-pasteable boilerplate for running a full web application in a micro-services style. Many pieces are optional and could be swapped out to match others desires.

## Assumptions and Opinions
* Alpine Linux is my prefered containerized OS, and the choice I've made for images
* CoreOS is the chosen host operating system
  * fleet comes for free for orchestration
  * etcd comes for free for a key value store

## Requirements and Features
* Dockerized nginx container to host static site
  * Forward's nginx logs to the docker service, [loggly logging strategy article](https://www.loggly.com/blog/top-5-docker-logging-methods-to-fit-your-container-deployment-strategy/)
  * Automatically reconfigures and refreshes nginx config based on routing configuration provided through etcd
  * SSL termination
  * By default forward http connections to https
  * Have a configuration mode which allows initial letsencrypt validation over http
  * Oauth & Oauth2 Termination
    * JWT generation and validation
* Https certificate from letsencrypt with autorenewal
* Static Front End boilerplate, with static component upgrade strategy
* Containerized Node.js server with application upgrade strategy
  * Boilerplate to publish to etcd
  * Discovers database from etcd
* Dockerized  RethinkDB
  * Boilerplate to publish to etcd

## Externalities
* Configure DNS
* Configure SAN disks
* Create machine instances
* Firewall
* Create fleet cluster
    * Tag instances
* Machine instance monitoring

## Frontend
### nginx unit
The main unit for the front end, nginx is the static file server and reverse proxy. Can have redundant instances.

[nginx.service](units/nginx.service)
```yaml
[Unit]
Description=NGINX
After=docker.service
Requires=docker.service
Before=nginx-certificate-update.service nginx-site-update.service
Wants=nginx-certificate-update.service nginx-site-update.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx
ExecStartPre=-/usr/bin/docker rm nginx
ExecStart=/usr/bin/docker run --name nginx -p 80:80 -p 443:443 \
-v /var/www:/usr/share/nginx/html:ro -v /etc/ssl:/etc/nginx/ssl:ro \
-d chadautry/wac-nginx

[X-Fleet]
Global=true
MachineMetadata=frontend=true
```
* requires docker
* wants cert update
* wants app update
* Starts a customized nginx docker container
    * configured to route http --> https (except letsencrypt requests)
    * Takes html from local drive
    * Takes certs from local drive
    * Takes acme challenge response from local drive
    * Takes config from local drive
* runs on all frontend tagged instances

### nginx reloading units
A pair of units are responsible for reloading nginx instances on file changes

[nginx-reload.service](units/nginx-restart.service)
```yaml
[Unit]
Description=NGINX reload service

[Service]
ExecStart=-/usr/bin/docker kill -s HUP nginx
```
* Restarts the named nginx container
* Ignores errors
* Expects to be started locally, so doesn't have any machine metadata

[nginx-reload.path](units/nginx-reload.path)
```yaml
[Unit]
Description=NGINX reload path

[Path]
PathChanged=/var/www
PathChanged=/etc/ssl

[X-Fleet]
Global=true
MachineOf=nginx.service
```
* Watches config, certs, acme response, and webapp files
* Defaults to calling nginx-reload.service on change (because of matching unit name)
* Scheduled to run on all nginx service machines

### letsencrypt renewal unit
requires san disk

### nginx certificate update unit
requires san disk

### nginx static app update unit
requires san disk

### api endpoint discovery unit
## Backend
### nodejs unit
### nodejs code update unit
### api endpoint publishing unit
### RethinkDB unit

## Unit Files
[![Build Status](https://travis-ci.org/chad-autry/wac-bp.svg?branch=master)](https://travis-ci.org/chad-autry/wac-bp)

The unit files under the units directory have been extracted from this document and pushed back to the repo.

## Addendum
### SAN replacement possibilities
* Baked in Docker
* Shared read only disks

### Tips and Tools
* Pre-create/retrieve Unit files externally
* Script to launch units
* Sftp to move files easily
