# web-application cluster boiler-plate
Documentation and scripts for running a full web application in a micro-services style. Many pieces are optional and could be swapped out to match others desires.

## Transitioning to Ansible
Currentlly transitioning from fleet to ansible

# Unit Files, Scripts, Playbooks
[![Build Status](https://travis-ci.org/chad-autry/wac-bp.svg?branch=master)](https://travis-ci.org/chad-autry/wac-bp)

The unit files, scripts, and playbooks in the dist directory have been extracted from this document and pushed back to the repo.

# Assumptions and Opinions
* Alpine Linux is my prefered containerized OS, and the choice I've made for images
* CoreOS is the chosen host operating system
* Ansible is used for orchestration

# Requirements and Features
* Dockerized nginx container to host static site
  * Forward's nginx logs to the docker service, [loggly logging strategy article](https://www.loggly.com/blog/top-5-docker-logging-methods-to-fit-your-container-deployment-strategy/)
  * Automatically reconfigures and refreshes nginx config based on routing configuration provided through etcd
  * SSL termination
  * By default forward http connections to https
  * Have a configuration mode which allows initial letsencrypt validation over http
* Https certificate from letsencrypt with autorenewal
* Containerized Node.js server
  * Publishes to etcd for discovery
  * Expets DB proxy on localhost
  * Oauth & Oauth2 Termination
    * JWT generation and validation
* Dockerized RethinkDB
* Ansible based deployment and initialization

# Externalities
* Configure DNS
* Create tagged machine instances
* Create Ansible inventory (or use dynamic inventory script!)
* Firewall
* Machine instance monitoring

# Ansible Deployment
The machine used for a controller will need SSH access to all the machines being managed. You can use one of the instances being managed, on GCE [cloud shell](https://cloud.google.com/shell/docs/) is a handy resource to use. I'm personally running in GCE using [wac-gce-ansible](https://github.com/chad-autry/wac-gce-ansible)

## Ansible Inventory
Here is an example inventory. wac-bp operates on machines based on the group they belong to. You can manually create the inventory file with the hosts to manage, or use a dynamic inventory script for your cloud provider.

```
hostnameone
hostnametwo

[tag_etcd]
hostnameone

[tag_rethinkdb]
hostnameone

[tag_frontend]
hostnametwo

[tag_backend]
hostnametwo
```

## group_vars/all
The all variables file contains all the container versions to use.

[group_vars/all](dist/ansible/group_vars/all)
```yaml
---
# CoreOS can't have python installed at the normal /etc/bin. Override in inventory for localhost (if not CoreOS)
ansible_python_interpreter: /opt/bin/python
# The host value which will be templated out for intra-machine connectivity. Match your manual inventory or dynamic inventory variable
internal_ip_name: gce_private_ip
# The unique name of machine instances to be used in templates
machine_name: gce_name

# Variables which get set into etcd (some of them are private!) needed by other applications
domain_name: <domain_name>
domain_email: <domain_email>
rethinkdb_web_password: <rethinkdb_web_password>

# Variables templated into the backend node process(es)
node_config:
    backend:
        jwt_token_secret: <jwt_token_secret>
        google_client_id: <google_client_id>
        google_redirect_uri: <google_redirect_uri>
        google_auth_secret: <google_auth_secret>

# Location of the frontend app on the controller.
frontend_src_path: /home/frontend/src

# Location of source(s) on the controller for the nodejs process(es)
node_src_path: 
    backend: /home/backend/src

# The controller machine directory to stage archives at
controller_src_staging: /home/staging

# The container versions to use
rsync_version: latest
etcd_version: latest
nginx_version: latest
nginx_config_templater_version: latest
wac_acme_version: latest
nodejs_version: latest
```

# Playbooks
## site.yml
The main playbook that deploys or updates a cluster

[site.yml](dist/ansible/site.yml)
```yml
# Make sure python is installed
- hosts: all:!localhost
  gather_facts: false
  become: true
  roles:
    - coreos-python

# Place a full etcd on the etcd hosts
- hosts: tag_etcd
  become: true
  roles:
    - { role: etcd, proxy_etcd: False }

# Set the etcd values (if required) from the first etcd host
- hosts: tag_etcd[0]
  become: true
  roles:
    - populate_etcd

# Place a proxy etcd everywhere except the etcd hosts
- hosts: all:!tag_etcd:!localhost
  become: true
  roles:
    - { role: etcd, proxy_etcd: True }

- name: Remove old staging directory
  hosts: localhost
  tasks:
    - file:
        path: "{{controller_src_staging}}"
        state: absent
    
# Recreate localhost staging directory
- name: Create local staging directory
  hosts: localhost
  tasks:
    - file:
        state: directory
        path: "{{controller_src_staging}}"

# nginx
- hosts: tag_frontend
  become: true
  roles:
    - frontend

# Default Backend nodejs process. Role can be applied additional times to different hosts with different configuration
- hosts: tag_backend
  become: true
  roles:
    - { role: nodejs, identifier: backend, port: 8080, discoverable: True, route: backend, strip_route: True, authenticate_route: False }
```

# Roles
The roles used by the playbooks above

## coreos-ansible
Install Python onto CoreOS hosts

[roles/coreos-python/tasks/main.yml](dist/ansible/roles/coreos-python/tasks/main.yml)
```yml
- name: Check if bootstrap is needed
  raw: stat /opt/bin/python
  register: need_bootstrap
  ignore_errors: True

- name: Run bootstrap.sh
  script: bootstrap.sh
  when: need_bootstrap | failed
```

[roles/coreos-python/files/bootstrap.sh](dist/ansible/roles/coreos-python/files/bootstrap.sh)
```bash
#/bin/bash

set -e

cd

if [[ -e /opt/bin/python ]]; then
  exit 0
fi

PYPY_VERSION=5.1.0

if [[ -e $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2 ]]; then
  tar -xjf $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2
  rm -rf $HOME/pypy-$PYPY_VERSION-linux64.tar.bz2
else
  wget -O - https://bitbucket.org/pypy/pypy/downloads/pypy-$PYPY_VERSION-linux64.tar.bz2 |tar -xjf -
fi

mkdir -p /opt/bin

mv -n pypy-$PYPY_VERSION-linux64 /opt/bin/pypy

## library fixup
mkdir -p /opt/bin/pypy/lib
ln -snf /lib64/libncurses.so.5.9 /opt/bin/pypy/lib/libtinfo.so.5

cat > /opt/bin/python <<EOF
#!/bin/bash
LD_LIBRARY_PATH=/opt/bin/pypy/lib:$LD_LIBRARY_PATH exec /opt/bin/pypy/bin/pypy "\$@"
EOF

chmod +x /opt/bin/python
/opt/bin/python --version
```

## etcd
Deploys or redeploys the etcd instance on a host. Etcd is persistent, but if the cluster changes wac-bp blows it away instead of attempting to add/remove instances. Deploys a full instance or proxy instance depending on the variable passed

[roles/etcd/tasks/main.yml](dist/ansible/roles/etcd/tasks/main.yml)
```yml
# template out the systemd etcd.service unit on the etcd hosts
- name: etcd template
  template:
    src: etcd.service
    dest: /etc/systemd/system/etcd.service
  register: etcd_template

- name: wipe out etcd directory
  file:
    state: absent
    path: /var/etcd
  when: etcd_template | changed
    
- name: ensure etcd directory is present
  file:
    state: directory
    path: /var/etcd
  when: etcd_template | changed

- name: start/restart the etcd.service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: etcd.service
  when: etcd_template | changed
```

### etcd systemd unit template
[roles/etcd/templates/etcd.service](dist/ansible/roles/etcd/templates/etcd.service)
```yaml
[Unit]
Description=etcd
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-etcdv2:{{etcd_version}}
ExecStartPre=-/usr/bin/docker rm etcd
ExecStart=/usr/bin/docker run --name etcd --net host -p 2380:2380 -p 2379:2379 \
-v /var/etcd:/var/etcd \
chadautry/wac-etcdv2:{{etcd_version}} \
{% if not proxy_etcd %}
--initial-advertise-peer-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2380 \
--listen-peer-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2380 \
--advertise-client-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2379 \
--data-dir /var/etcd \
--initial-cluster-state new \
{% endif %}
{% if proxy_etcd %}
--proxy on \
{% endif %}
--name {{hostvars[inventory_hostname][machine_name]}} \
--listen-client-urls http://{{hostvars[inventory_hostname][internal_ip_name]}}:2379,http://127.0.0.1:2379 \
--initial-cluster {% for host in groups['tag_etcd']  %}{{hostvars[host][machine_name]}}=http://{{hostvars[host][internal_ip_name]}}:2380{% if not loop.last %},{% endif %}{% endfor %}

Restart=always
````
* requires docker
* takes version from etcd_version variable
* writes different lines for proxy mode or standard
* uses the internal ip variable configured
* walks the etcd hosts for the initial cluster

## populate_etcd
This role sets values into etcd from the Ansible config when the etcd cluster has been recreated. It only needs to be executed from a single etcd machine.

[roles/populate_etcd/tasks/main.yml](dist/ansible/roles/populate_etcd/tasks/main.yml)
```yml
# Condititionally import the populate.yml, so we don't have to see all the individual set tasks excluded in the output
- include: populate.yml
  static: no
  when: (etcd_template | changed) or (force_populate_etcd is defined)
```

[roles/populate_etcd/tasks/populate.yml](dist/ansible/roles/populate_etcd/tasks/populate.yml)
```yml
- name: /usr/bin/etcdctl set /domain/name <domain>
  command: /usr/bin/etcdctl set /domain/name {{domain_name}}
  
- name: /usr/bin/etcdctl set /domain/email <email>
  command: /usr/bin/etcdctl set /domain/email {{domain_email}}
  
- name: /usr/bin/etcdctl set /rethinkdb/pwd <Web Authorization Password>
  command: /usr/bin/etcdctl set /rethinkdb/pwd {{rethinkdb_web_password}}
```

## frontend
The front end playbook sets up the nginx unit, the nginx file watching & reloading units, the letsencrypt renewal units, and finally pushes the front end application across (tagged so it can be executed alone)

[roles/frontend/tasks/main.yml](dist/ansible/roles/frontend/tasks/main.yml)
```yml
# Ensure the frontend directories are created
- name: ensure www directory is present
  file:
    state: directory
    path: /var/www
    
- name: ensure nginx directory is present
  file:
    state: directory
    path: /var/nginx
    
- name: ensure ssl directory is present
  file:
    state: directory
    path: /var/ssl
    
# Import backend route configurator (creates config before nginx starts)
- include: backend-discovery-watcher.yml

# Import nginx task file
- include: nginx.yml

# Import ssl related tasks
- include: ssl.yml

# Import application push task
- include: application.yml
```

### nginx
Nginx hosts static files, routes to instances (backends and databases), and terminates SSL according to its configuration

#### nginx task include
[roles/frontend/tasks/nginx.yml](dist/ansible/roles/frontend/tasks/nginx.yml)
```yml
# template out the systemd nginx-reload.service unit
- name: nginx-reload.service template
  template:
    src: nginx-reload.service
    dest: /etc/systemd/system/nginx-reload.service
    
# template out the systemd nginx-reload.path unit
- name: nginx-reload.path template
  template:
    src: nginx-reload.path
    dest: /etc/systemd/system/nginx-reload.path
    
- name: Start nginx-reload.path
  systemd:
    daemon_reload: yes
    state: restarted
    name: nginx-reload.path

# template out the systemd nginx.service unit
- name: nginx.service template
  template:
    src: nginx.service
    dest: /etc/systemd/system/nginx.service
  register: nginx_template
    
- name: start/restart nginx.service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: nginx.service
  when: nginx_template | changed
```

#### nginx systemd service unit template

[roles/frontend/templates/nginx.service](dist/ansible/roles/frontend/templates/nginx.service)
```yaml
[Unit]
Description=NGINX
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx:{{nginx_version}}
ExecStartPre=-/usr/bin/docker rm nginx
ExecStart=/usr/bin/docker run --name nginx -p 80:80 -p 443:443 \
-v /var/www:/usr/share/nginx/html:ro -v /var/ssl:/etc/nginx/ssl:ro \
-v /var/nginx:/usr/var/nginx:ro \
chadautry/wac-nginx:{{nginx_version}}
Restart=always
```
* requires docker
* Starts a customized nginx docker container
    * Version comes from variables
    * Takes server config from local drive
    * Takes html from local drive
    * Takes certs from local drive

#### nginx configuration watching
A pair of units are responsible for watching the nginx configuration and reloading the service

[roles/frontend/templates/nginx-reload.service](dist/ansible/roles/frontend/templates/nginx-reload.service)
```yaml
[Unit]
Description=NGINX reload service

[Service]
ExecStart=-/usr/bin/docker kill -s HUP nginx
Type=oneshot
```
* Sends a signal to the named nginx container to reload
* Ignores errors
* It is a one shot which expects to be called by other units

[roles/frontend/templates/nginx-reload.path](dist/ansible/roles/frontend/templates/nginx-reload.path)
```yaml
[Unit]
Description=NGINX reload path

[Path]
PathChanged=/var/nginx/nginx.conf
PathChanged=/var/ssl/fullchain.pem
```
* Watches config file
* Watches the (last copied) SSL cert file
* Automatically calls nginx-reload.service on change (because of matching unit name)

### nginx route discovery
Sets a watch on the backend discovery location, and when it changes templates out the nginx conf

#### route-discovery-watcher task include
TODO Why isn't this a part of the nginx task?
[roles/frontend/tasks/backend-discovery-watcher.yml](dist/ansible/roles/frontend/tasks/backend-discovery-watcher.yml)
```yml
# template out the systemd service unit
- name: backend-discovery-watcher.service template
  template:
    src: backend-discovery-watcher.service
    dest: /etc/systemd/system/backend-discovery-watcher.service
  register: backend_discovery_watcher_template
    
- name: start/restart the service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: backend-discovery-watcher.service
  when: backend_discovery_watcher_template | changed
```

#### route-discovery-watcher systemd unit template
[roles/frontend/templates/backend-discovery-watcher.service](dist/ansible/roles/frontend/templates/backend-discovery-watcher.service)
```yaml
[Unit]
Description=Watches for backened instances
# Dependencies
Requires=etcd.service

# Ordering
After=etcd.service

# Restart when dependency restarts
PartOf=etcd.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx-config-templater:{{nginx_config_templater_version}}
ExecStartPre=-/usr/bin/docker rm nginx-templater
ExecStart=/usr/bin/etcdctl watch /discovery/backend
ExecStartPost=-/usr/bin/docker run --name nginx-templater --net host \
-v /var/nginx:/usr/var/nginx -v /var/ssl:/etc/nginx/ssl:ro \
chadautry/wac-nginx-config-templater:{{nginx_config_templater_version}}
Restart=always
```
* Restarted if etcd restarts
* Starts a watch for changes in the backend discovery path
* Once the watch starts, executes the config templating container
    * Local volume mapped in for the templated config to be written to
    * Local ssl volume mapped in for the template container to read
    * Doesn't error out (TODO move to a secondary unit to be safely concurrent)
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and templater execution

### SSL
The SSL certificate is requested from letsencrypt

#### SSL task include
[roles/frontend/tasks/acme-response-watcher.yml](dist/ansible/roles/frontend/tasks/ssl.yml)
```yml
# template out the systemd certificate-sync.service unit
- name: certificate-sync.service template
  template:
    src: certificate-sync.service
    dest: /etc/systemd/system/certificate-sync.service
  register: certificate_sync_template
    
- name: start/restart the certificate-sync.service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: certificate-sync.service
  when: certificate_sync_template | changed

# template out the systemd acme-response-watcher.service unit
- name: acme-response-watcher.service template
  template:
    src: acme-response-watcher.service
    dest: /etc/systemd/system/acme-response-watcher.service
  register: acme_response_watcher_template
    
- name: start/restart the acme-response-watcher.service if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: acme-response-watcher.service
  when: acme_response_watcher_template | changed
 
 # template out the systemd letsencrypt renewal units
- name: letsencrypt-renewal.service template
  template:
    src: letsencrypt-renewal.service
    dest: /etc/systemd/system/letsencrypt-renewal.service
  
- name: letsencrypt-renewal.timer template
  template:
    src: letsencrypt-renewal.timer
    dest: /etc/systemd/system/letsencrypt-renewal.timer
  register: letsencrpyt_renewal_template

- name: start/restart the letsencrypt-renewal.timer if template changed
  systemd:
    daemon_reload: yes
    state: restarted
    name: letsencrypt-renewal.timer
  when: letsencrpyt_renewal_template | changed
```

#### SSL certificate-sync systemd unit template
This unit takes the SSL certificates from etcd, and writes them to the local system. It also atempts to set the local certificate back into etcd (for whenever etcd is reset due to a cluster change)

[roles/frontend/templates/certificate-sync.service](dist/ansible/roles/frontend/templates/certificate-sync.service)
```yaml
[Unit]
Description=SSL Certificate Syncronization
# Dependencies
Requires=etcd.service

# Ordering
After=etcd.service

# Restart when dependency restarts
PartOf=etcd.service

[Service]
ExecStartPre=-/bin/sh -c '/usr/bin/etcdctl mk -- /ssl/server_chain "$(cat /var/ssl/chain.pem)"'
ExecStartPre=-/bin/sh -c '/usr/bin/etcdctl mk -- /ssl/key "$(cat /var/ssl/privkey.pem)"'
ExecStartPre=-/bin/sh -c '/usr/bin/etcdctl mk -- /ssl/server_pem "$(cat /var/ssl/fullchain.pem)"'
ExecStartPre=-/bin/sh -c '/usr/bin/etcdctl mk /ssl/watched "$(date +%s%N)"'
ExecStart=/usr/bin/etcdctl watch /ssl/watched
ExecStartPost=/bin/sh -c '/usr/bin/etcdctl get /ssl/server_chain > /var/ssl/chain.pem'
ExecStartPost=/bin/sh -c '/usr/bin/etcdctl get /ssl/key > /var/ssl/privkey.pem'
ExecStartPost=/bin/sh -c '/usr/bin/etcdctl get /ssl/server_pem > /var/ssl/fullchain.pem'
Restart=always
```
* Sets the local certs into etcd if they don't exist there
    * -- Means there are no more command options, needed since the cert files start with '-'
* Creates /ssl/watched if it doesn't exist, so the unit has something to watch
* Starts a watch for SSL cert changes to copy
* Once the watch starts, copy the current certs
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and copy

#### SSL acme-response-watcher systemd unit template
This unit watches etcd for the acme challenge response, and then calls the nginx-config-templater (the templater writes the response into the nginx config)
[roles/frontend/templates/acme-response-watcher.service](dist/ansible/roles/frontend/templates/acme-response-watcher.service)
```yaml
[Unit]
Description=Watches for distributed acme challenge responses
# Dependencies
Requires=etcd.service

# Ordering
After=etcd.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx-config-templater:{{nginx_config_templater_version}}
ExecStartPre=-/usr/bin/docker rm nginx-templater
ExecStart=/usr/bin/etcdctl watch /acme/watched
ExecStartPost=-/usr/bin/docker run --name nginx-templater --net host \
-v /var/nginx:/usr/var/nginx -v /var/ssl:/etc/nginx/ssl:ro \
chadautry/wac-nginx-config-templater:{{nginx_config_templater_version}}
Restart=always
```
* Starts a watch for changes in the acme challenge response
* Once the watch starts, executes the config templating container
    * Local volume mapped in for the templated config to be written to
    * Doesn't error out (TODO move to a secondary unit to be safely concurrent)
* If the watch is ever satisfied, the unit will exit
* Automatically restarted, causing a new watch and templater execution

#### letsencrypt renewal units
A pair of units are responsible for initiating the letsencrypt renewal process. The process executes daily but will not renew until there are less than 30 days remaining till it expires

[roles/frontend/templates/letsencrypt-renewal.service](dist/ansible/roles/frontend/templates/letsencrypt-renewal.service)
```yaml
[Unit]
Description=Letsencrpyt renewal service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-acme:{{wac_acme_version}}
ExecStartPre=-/usr/bin/docker rm acme
ExecStart=-/usr/bin/docker run --net host -v /var/ssl:/var/ssl --name acme chadautry/wac-acme:{{wac_acme_version}}
Type=oneshot
```
* Calls the wac-acme container to create/renew the cert
    * Container takes domain name and domain admin e-mail from etcd
    * Container interacts with other units/containers to manage the renewal process through etcd
* Ignores errors
* It is a one shot which expects to be called by the timer unit
* Metadata will cause it to be made available on all frontend servers when loaded
    * It technically could run anywhere with etcd, just limiting its loaded footprint

> Special Deployment Note:
> * Put the admin e-mail and domain into etcd
> ```
> /usr/bin/etcdctl set /domain/name <domain>
> /usr/bin/etcdctl set /domain/email <email>
> ```
> * Manually run the wac-acme container once to obtain certificates the first time
> ```
> sudo docker run --net host -v /var/ssl:/var/ssl --name acme chadautry/wac-acme
> ```

[roles/frontend/templates/letsencrypt-renewal.timer](dist/ansible/roles/frontend/templates/letsencrypt-renewal.timer)
```yaml
[Unit]
Description=Letsencrpyt renewal timer

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=1800
```
* Executes daily at 5:00 (to avoid DST issues)
* Has a 30 minute randomized delay, so multiple copies don't all try to execute at once (though the docker image itself will exit if another is already running)
* Automagically executes the letsencrypt-renewal.service based on name

### Frontend Application
This task include takes the static front end application and pushes it across to instances

[roles/frontend/tasks/application.yml](dist/ansible/roles/frontend/tasks/application.yml)
```yml
# Create archive of frontend content to transfer
- name: archive frontend on localhost
  local_action: archive
  args:
    path: "{{frontend_src_path}}"
    dest: "{{controller_src_staging}}/frontendsrc.tgz"
  become: false
  run_once: true

- name: Remove old webapp staging
  file:
    path: /var/staging/webapp
    state: absent

- name: Ensure remote staging dir exists
  file:
    path: /var/staging
    state: directory

- name: Transfer and unpack webapp to staging
  unarchive:
    src: "{{controller_src_staging}}/frontendsrc.tgz"
    dest: /var/staging
    
- name: Pull alpine-rsync image		
  command: /usr/bin/docker pull chadautry/alpine-rsync:{{rsync_version}}
   
- name: sync staging and /var/www	
  command: /usr/bin/docker run -v /var/staging:/var/staging -v /var/www:/var/www --rm chadautry/alpine-rsync:{{rsync_version}} -a /var/staging/webapp/ /var/www
```
## nodejs
This role sets up a nodejs unit, the discovery unit, and finally pushes the source application across (tagged so it can be executed alone). Configureable for hosting multiple nodejs processes with multiple disocvered routes

[roles/nodejs/tasks/main.yml](dist/ansible/roles/nodejs/tasks/main.yml)
```yml  
# Ensure the backend directories are created
- name: ensure application directory is present
  file:
    state: directory
    path: /var/nodejs/{{identifier}}

# Deploy the process's application source
- include: application.yml

# Template out the nodejs config
- name: config.js template
  template:
    src: config.js
    dest: /var/nodejs/{{identifier}}/config.js

# Template out the nodejs systemd unit
- name: nodejs.service template
  template:
    src: nodejs.service
    dest: /etc/systemd/system/{{identifier}}_nodejs.service

# Always restart the nodejs server
- name: start/restart the nodejs.service
  systemd:
    daemon_reload: yes
    state: restarted
    name: "{{identifier}}_nodejs.service"
    
# Template out the nodejs route-publishing systemd unit
- name: route-publishing.service template
  template:
    src: backend-publishing.service
    dest: /etc/systemd/system/{{identifier}}_route-publishing.service
  when: discoverable

# Start the discovery publisher
- name: start/restart the route-publishing.service
  systemd:
    daemon_reload: yes
    state: started
    name: "{{identfier}}_route-publishing.service"
  when: discoverable
```

### nodejs Application
This task include takes the static application source and pushes it across to instances

[roles/nodejs/tasks/application.yml](dist/ansible/roles/nodejs/tasks/application.yml)
```yml
# Create archive of application files to transfer
- name: archive application on localhost
  local_action: archive
  args:
    path: "{{node_src_path[identifier]}}/*"
    dest: "{{controller_src_staging}}/{{identifier}}src.tgz"
  become: false
  run_once: true

- name: Remove old nodejs staging
  file:
    path: /var/staging/{{identifier}}
    state: absent

- name: Ensure nodejs staging dir exists
  file:
    path: /var/staging/{{identifier}}
    state: directory

- name: Transfer nodejs application archive
  copy:
    src: "{{controller_src_staging}}/{{identifier}}src.tgz"
    dest: /var/staging
    
# Using the unarchive module caused errors. Presumably due to the large number of files in node_modules
- name: Unpack nodejs application archive
  command: /bin/tar --extract -C /var/staging/{{identifier}} -z -f /var/staging/{{identifier}}src.tgz
  args:
    warn: no
    
- name: Pull alpine-rsync image		
  command: /usr/bin/docker pull chadautry/alpine-rsync:{{rsync_version}}
   
- name: sync staging and /var/nodejs	
  command: /usr/bin/docker run -v /var/staging/{{identifier}}:/var/staging/{{identifier}} -v /var/nodejs/{{identifier}}:/var/nodejs/{{identifier}} --rm chadautry/alpine-rsync:{{rsync_version}} -a /var/staging/{{identifier}}/ /var/nodejs/{{identifier}}
```

### nodejs config.js template
The template for the nodejs server's config
[roles/nodejs/templates/config.js](dist/ansible/roles/nodejs/templates/config.js)
```javascript
module.exports = {
  PORT: 80,
{%- for key in node_config[identifier] %}
  {{key}}: '{{node_config[identifier][key]}}'{% if not loop.last %},{% endif %}
{%- endfor %}
};
```

### nodejs systemd unit template
The main application unit, it is simply a docker container with Node.js installed and the code to be executed mounted inside

[roles/nodejs/templates/nodejs.service](dist/ansible/roles/nodejs/templates/nodejs.service)
```yaml
[Unit]
Description=NodeJS Backend API
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-node
ExecStartPre=-/usr/bin/docker rm -f backend-node-container
ExecStart=/usr/bin/docker run --name backend-node-container -p {{port}}:80 \
-v /var/nodejs/{{identifier}}:/app:ro \
chadautry/wac-node
ExecStop=-/usr/bin/docker stop backend-node-container
Restart=always
```
* requires docker
* Starts a customized nodejs docker container
    * Takes the app and configuration from local drive

### nodejs route-publishing systemd unit template
Publishes the backend host into etcd at an expected path for the frontend to route to

[roles/nodejs/templates/route-publishing.service](dist/ansible/roles/nodejs/templates/route-publishing.service)
```yaml
[Unit]
Description=Backend Publishing
# Dependencies
Requires=etcd.service
Requires={{identifier}}_nodejs.service

# Ordering
After=etcd.service
After={{identifier}}_nodejs.service

# Restart when dependency restarts
PartOf=etcd.service
PartOf={{identifier}}_nodejs.service

[Service]
ExecStart=/bin/sh -c "while true; do etcdctl set /discovery/{{route}}/hosts/%H/host '%H' --ttl 60 \
etcdctl set /discovery/{{route}}/hosts/%H/port '{{http_port}}' --ttl 60 \
etcdctl set /discovery/{{route}}/strip 'true' --ttl 60 \
etcdctl set /discovery/{{route}}/private 'false' --ttl 60 \
sleep 45 \
done"
ExecStop=/usr/bin/etcdctl rm /discovery/{{route}}/hosts/%H
```
* requires etcd
* Publishes host into etcd every 45 seconds with a 60 second duration
* Deletes host from etcd on stop
* Is restarted if etcd or nodejs restarts

### rethinkdb proxy unit
A rethinkdb proxy on localhost for nodejs units to connect to

[rethinkdb-proxy.service](dist/units/started/rethinkdb-proxy.service)
```yaml
[Unit]
Description=RethinkDB Proxy
# Dependencies
Requires=docker.service
Requires=etcd2.service

# Ordering
After=docker.service
After=etcd2.service

[Service]
ExecStartPre=-mkdir /var/rethinkdbproxy
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb-config-templater
ExecStartPre=-/usr/bin/docker run \
--net host --rm \
-v /var/rethinkdbproxy:/usr/var/rethinkdb \
chadautry/wac-rethinkdb-config-templater "emptyHost"
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb
ExecStartPre=-/usr/bin/docker rm -f rethinkdb-proxy
ExecStartPre=-rm /var/rethinkdbproxy/pid_file
ExecStart=/usr/bin/docker run --name rethinkdb-proxy \
-v /var/rethinkdbproxy:/usr/var/rethinkdb \
-p 29017:29015 -p29018:29016 -p 8082:8080 \
chadautry/wac-rethinkdb proxy --config-file /usr/var/rethinkdb/rethinkdb.conf
Restart=always

[X-Fleet]
Global=true
MachineMetadata=backend=true
```
* requires docker
* Configures the instance, will not exclude any host from join list
* Pulls the image
* Removes the container
* Starts a rethinkdb container in proxy mode
* All ports shifted by 2, so it won't conflict with a non-proxy node
* Blindly runs on all backend tagged instances

## Database

### rethinkdb unit
A rethinkdb node

[rethinkdb.service](dist/units/started/rethinkdb.service)
```yaml
[Unit]
Description=RethinkDB
# Dependencies
Requires=docker.service
Requires=etcd2.service

# Ordering
After=docker.service
After=etcd2.service

[Service]
ExecStartPre=-mkdir /var/rethinkdb
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb-config-templater
ExecStartPre=-/usr/bin/docker run \
--net host --rm \
-v /var/rethinkdb:/usr/var/rethinkdb \
chadautry/wac-rethinkdb-config-templater %H
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb
ExecStartPre=-/usr/bin/docker rm -f rethinkdb
ExecStartPre=-rm /var/rethinkdb/pid_file
ExecStart=/usr/bin/docker run --name rethinkdb \
-v /var/rethinkdb:/usr/var/rethinkdb \
-p 29015:29015 -p29016:29016 -p 8081:8080 \
chadautry/wac-rethinkdb --config-file /usr/var/rethinkdb/rethinkdb.conf
Restart=always

[X-Fleet]
Global=true
MachineMetadata=database=true
```
* requires docker
* Configures the instance, will exclude its own host from the join list
* Pulls the image
* Removes the container
* Starts a rethinkdb container
* HTTP shifted to 8081 so it won't conflict with nginx if colocated
* Blindly runs on all database tagged instances

> DB Instance Prep:
> There is some prep that needs to be done manually on each DB instance
> ```
> docker run --rm -v /var/rethinkdb:/usr/var/rethinkdb chadautry/wac-rethinkdb create -d /var/rethinkdb/data
> sudo etcd set /discovery/database/<host> <host>
> ```
