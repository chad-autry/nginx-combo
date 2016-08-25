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
* Create machine instances
* Firewall
* Create fleet cluster
    * Tag instances
* Machine instance monitoring

## Frontend
### nginx unit
The main unit for the front end, nginx is the static file server and reverse proxy. Can have redundant identical instances.

[nginx.service](units/nginx.service)
```yaml
[Unit]
Description=NGINX
# Dependencies
Requires=docker.service
Wants=certificate-copy.service
Wants=nginx-config-copy.service
Wants=acme-response-copy.service

# Ordering
After=docker.service
After=certificate-copy.service
After=nginx-config-copy.service
After=acme-response-copy.service

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
* wants all files to be copied before startup
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
Type=oneshot
```
* Sends a signal to the named nginx container to reload
* Ignores errors
* It is not a oneshot and not a persistent service
* Expects to be started locally, so doesn't have any machine metadata
    * Make sure to load the unit so it is available 

[nginx-reload.path](units/nginx-reload.path)
```yaml
[Unit]
Description=NGINX reload path

[Path]
PathChanged=/etc/ssl
#TODO Add Local Config Path

[X-Fleet]
Global=true
MachineOf=nginx.service
```
* Watches config and certs
    * Static files (acme response and html) don't need to be watched
* Automatically calls nginx-reload.service on change (because of matching unit name)
* Scheduled to run on all nginx service machines, don't fiddle with binding

### nginx config watcher and copier
* Watches value in etcd
* Metadata driven, don't bother with binding

### acme response watcher and copier
* Watches value in etcd
* Metadata driven, don't bother with binding

### ssl cert watcher and copier
* Watches value in etcd
* Metadata driven, don't bother with binding

### letsencrypt renewal unit
* Scheduled to run once a month
* Writes acme challenge response to etcd (< 1 MB)
* Writes certificate to etcd (< 1 MB)

### nginx static app update unit
Want to load app once, and have it distribute automatically

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

### Tips and Tools
* Pre-create/retrieve Unit files externally
* Script to launch units
* Sftp to move files easily
