# web-application cluster boiler-plate
Documentation and scripts for running a full web application in a micro-services style. Many pieces are optional and could be swapped out to match others desires.

# Unit Files, Scripts, Playbooks
[![Build Status](https://travis-ci.org/chad-autry/wac-bp.svg?branch=master)](https://travis-ci.org/chad-autry/wac-bp)

The unit files, scripts, and playbooks in the dist directory have been extracted from this document and pushed back to the repo.

# Assumptions and Opinions
* Alpine Linux is my prefered containerized OS, and the choice I've made for images
* CentOS is the chosen host operating system. Originally was CoreOS, but proved incompatible with Python for Ansible
* Ansible is used for orchestration

# Requirements and Features
* Metrics gathered by Prometheus
  * Displayed with Grafana
* Dockerized nginx container to host static site
  * TODO: Forward's nginx logs to the docker service, [loggly logging strategy article](https://www.loggly.com/blog/top-5-docker-logging-methods-to-fit-your-container-deployment-strategy/)
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

# Ansible Deployment
The machine used for a controller will need SSH access to all the machines being managed. You can use one of the instances being managed, on GCE [cloud shell](https://cloud.google.com/shell/docs/) is a handy resource to use. I'm personally running in GCE using [wac-gce-ansible](https://github.com/chad-autry/wac-gce-ansible)

## Ansible Inventory
Here is an example inventory. wac-bp operates on machines based on the group they belong to. You can manually create the inventory file with the hosts to manage, or use a dynamic inventory script for your cloud provider.

```
hostnameone
hostnametwo

[etcd]
hostnameone

[rethinkdb]
hostnameone

[frontend]
hostnametwo

[backend]
hostnametwo

[prometheus]
hostnametwo
```

## group_vars/all
The all variables file contains all the container versions to use.

[group_vars/all](dist/ansible/group_vars/all)
```yaml
---
# The host value which will be templated out for intra-machine connectivity. Match your manual inventory or dynamic inventory variable
internal_ip_name: private_ip
# The unique name of machine instances to be used in templates
machine_name: name

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

# Ports map
ports:
    backend: 8080
    etcd_peer: 2380
    etcd_client: 2379
    prometheus: 9090
    grafana: 3000
    node_exporter: 9100
    nginx_prometheus_endpoint: 9145
    rethinkdb_peer: 29015
    rethinkdb_client: 28015
    rethinkdb_admin: 8081

# The container versions to use
rsync_version: latest
etcd_version: latest
nginx_version: latest
nginx_config_templater_version: latest
wac_acme_version: latest
nodejs_version: latest
rethinkdb_version: latest
prometheus_version: latest
node_exporter_version: latest
grafana_version: latest
```

# Playbooks
## site.yml
The main playbook that deploys or updates a cluster

[site.yml](dist/ansible/site.yml)
```yml
# Make sure Docker is installed
- hosts: all:!localhost
  gather_facts: false
  become: true
  roles:
    - docker

# Place a full etcd on the etcd hosts
- hosts: etcd
  become: true
  roles:
    - { role: etcd, proxy_etcd: False, tags: [ 'etcd' ] }

# Set the etcd values (if required) from the first etcd host
- hosts: etcd[0]
  become: true
  roles:
    - { role: populate_etcd, tags: [ 'etcd' ] }

# Place a proxy etcd everywhere except the etcd hosts
- hosts: all:!etcd:!localhost
  become: true
  roles:
    - { role: etcd, proxy_etcd: True, tags: [ 'etcd' ] }

# Place Prometheus on the Prometheus hosts
- hosts: prometheus
  become: true
  roles:
    - { role: prometheus, tags: [ 'prometheus' ] }

# Place Grafana as the frontend on the Prometheus hosts
- hosts: prometheus
  become: true
  roles:
    - { role: grafana, tags: [ 'grafana' ] }

# Place prometheus\node_exporter everywhere
- hosts: all:!localhost
  become: true
  roles:
    - { role: prometheus-node-exporter, tags: [ 'prometheus_node_exporter' ] }

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
- hosts: frontend
  become: true
  roles:
    - { role: frontend, tags: [ 'frontend' ] }

# Default Backend nodejs process. Role can be applied additional times to different hosts with different configuration
- hosts: backend
  become: true
  roles:
    - { role: nodejs, identifier: backend, nodejs_port: "{{ports['backend']}}", tags: [ 'backend' ] }
    - { role: discovery, parent: 'route_discovery', service: backend, port: "{{ports['backend']}}", service_properties: {strip: false, private: false}}, tags: [ 'backend' ] }

# Place a full RethinkDB on the RethinkDB hosts
- hosts: rethinkdb
  become: true
  roles:
    - { role: rethinkdb, proxy_rethinkdb: False }

# Place a proxy RethinkDB alongside application instances (edit the hosts when there are various types)
- hosts: backend:!rethinkdb
  become: true
  roles:
    - { role: rethinkdb, proxy_rethinkdb: True }
```

## status.yml
A helper playbook that queries the systemctl status of all wac-bp deployed units and displays them locally

[status.yml](dist/ansible/status.yml)
```yml
# check on etcd
- hosts: all:!localhost
  become: true
  tasks:
  - name: Check if etcd and etcd proxy is running
    no_log: True
    command: systemctl status etcd.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_etcd_status
  - name: Report status of etcd
    debug:
      msg: "{{service_etcd_status.stdout.split('\n')}}"

# check on prometheus
- hosts: prometheus
  become: true
  tasks:
  - name: Check if prometheus is running
    no_log: True
    command: systemctl status prometheus.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_prometheus_status
  - name: Report status of prometheus
    debug:
      msg: "{{service_prometheus_status.stdout.split('\n')}}"
  - name: Check if prometheus route-publishing is running
    no_log: True
    command: systemctl status prometheus-route-publishing.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: prometheus_route_publishing_status
  - name: Report status of prometheus-route-publishing
    debug:
      msg: "{{prometheus_route_publishing_status.stdout.split('\n')}}"

# check on prometheus-node_exporter
- hosts: all:!localhost
  become: true
  tasks:
  - name: Check if prometheus is running
    no_log: True
    command: systemctl status prometheus-node-exporter.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_prometheus_node_exporter_status
  - name: Report status of prometheus-node_exporter
    debug:
      msg: "{{service_prometheus_node_exporter_status.stdout.split('\n')}}"

# check on grafana
- hosts: prometheus
  become: true
  tasks:
  - name: Check if grafana is running
    no_log: True
    command: systemctl status grafana.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_grafana_status
  - name: Report status of grafana
    debug:
      msg: "{{service_grafana_status.stdout.split('\n')}}"

# check on frontend services
- hosts: frontend
  become: true
  tasks:
  - name: Check if nginx is running
    no_log: True
    command: systemctl status nginx.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_nginx_status
  - name: Report status of nginx
    debug:
      msg: "{{service_nginx_status.stdout.split('\n')}}"
  - name: Check if nginx-reload is running
    no_log: True
    command: systemctl status nginx-reload.path --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_nginx_reload_status
  - name: Report status of nginx-reload
    debug:
      msg: "{{service_nginx_reload_status.stdout.split('\n')}}"
  - name: Check if route-discovery-watcher is running
    no_log: True
    command: systemctl status route-discovery-watcher.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_route_discovery_watcher_status
  - name: Report status of nginx-reload
    debug:
      msg: "{{service_route_discovery_watcher_status.stdout.split('\n')}}"
  - name: Check if certificate-sync is running
    no_log: True
    command: systemctl status certificate-sync.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_certificate_sync_status
  - name: Report status of certificate-sync
    debug:
      msg: "{{service_certificate_sync_status.stdout.split('\n')}}"
  - name: Check if acme-response-watcher is running
    no_log: True
    command: systemctl status acme-response-watcher.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_acme_response_watcher_status
  - name: Report status of acme-response-watcher
    debug:
      msg: "{{service_acme_response_watcher_status.stdout.split('\n')}}"
  - name: Check if letsencrypt-renewal.timer is running
    no_log: True
    command: systemctl status letsencrypt-renewal.timer
    ignore_errors: yes
    changed_when: false
    register: service_letsencrypt_renewal_status
  - name: Report status of letsencrypt-renewal.timer
    debug:
      msg: "{{service_letsencrypt_renewal_status.stdout.split('\n')}}"
      
# check on backend services
- hosts: backend
  become: true
  tasks:
  - name: Check if nodejs is running
    no_log: True
    command: systemctl status backend_nodejs.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_backend_nodejs_status
  - name: Report status of nodejs
    debug:
      msg: "{{service_backend_nodejs_status.stdout.split('\n')}}"
  - name: Check if nodejs route-publishing is running
    no_log: True
    command: systemctl status backend_route-publishing.service --lines=0
    ignore_errors: yes
    changed_when: false
    register: service_backend_route_publishing_status
  - name: Report status of nodejs route-publishing
    debug:
      msg: "{{service_backend_route_publishing_status.stdout.split('\n')}}"
```

# Roles
The roles used by the playbooks above

## docker
Install Docker onto remote hosts

[roles/docker/tasks/main.yml](dist/ansible/roles/docker/tasks/main.yml)
```yml
- name: Install Docker
  shell: curl -fsSL https://get.docker.com/ | sh

- name: Ensure Docker is started
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: docker.service
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
    enabled: yes
    state: restarted
    name: etcd.service
  when: etcd_template | changed
  
- name: Ensure etcd is started, even if the template didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: etcd.service
  when: not (etcd_template | changed)
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
--initial-cluster {% for host in groups['etcd']  %}{{hostvars[host][machine_name]}}=http://{{hostvars[host][internal_ip_name]}}:2380{% if not loop.last %},{% endif %}{% endfor %}

Restart=always

[Install]
WantedBy=multi-user.target
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

## discovery publishing
The discovery publishing role is used to publish other services into etcd
It takes the service name, a parent path name, an optional group name, and a set of properties
It publishes the info into etcd for disocovery by other services

[roles/discovery/tasks/main.yml](dist/ansible/roles/discovery/tasks/main.yml)
```yml
# Template out the discovery publishing publishing systemd unit
- name: "{{service}}_{{parent}}_{{port}}-publishing.service template"
  template:
    src: publishing.service
    dest: /etc/systemd/system/{{service}}_{{parent}}_{{port}}-publishing.service
  register: "{{service}}_{{parent}}_{{port}}_publishing_template"

# Start/restart the discovery publisher when discoverable and template changed
- name: start/restart the discoverable-publishing.service
  systemd:
    daemon_reload: yes
    enabled: yes
    state: restarted
    name: "{{service}}_{{parent}}_{{port}}-publishing.service"
  when: "{{service}}_{{parent}}_{{port}}_publishing_template | changed"
  
# Ensure the discovery publisher is started even if template did not change
- name: start/restart the route-publishing.service
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: "{{service}}_{{parent}}_{{port}}-publishing.service"
  when: not ({{service}}_{{parent}}_{{port}}_publishing_template | changed)
```

### discovery publishing systemd unit template
Publishes the backend host into etcd at an expected path for the frontend to route to

[roles/discovery/templates/publishing.service](dist/ansible/roles/discovery/templates/publishing.service)
```yaml
[Unit]
Description={{service}} {{parent}} {{port}} Discovery Publishing
# Dependencies
Requires=etcd.service
Requires={{service}}.service

# Ordering
After=etcd.service
After={{service}}.service

# Restart when dependency restarts
PartOf=etcd.service
PartOf={{service}}.service

[Service]
ExecStart=/bin/sh -c "while true; do etcdctl set /{{parent}}/{{service}}/services/%H_{{port}}/host '%H' --ttl 60; \
                      etcdctl set /{{parent}}/{{service}}/services/%H_{{port}}/port '{{port}}' --ttl 60; \
                      {% if service_local_properties is defined %}
                      {% for item in service_local_properties  %}
                      etcdctl set /{{parent}}/{{service}}/services/%H_{{port}}/{{item.key}} '{{item.value}}' --ttl 60; \
                      {% endfor %}
                      {% endif %}
                      {% if service_properties is defined %}
                      {% for item in service_properties  %}
                      etcdctl set /{{parent}}/{{service}}/{{item.key}} '{{item.value}}' --ttl 60; \
                      {% endfor %}
                      {% endif %}
                      sleep 45; \
                      done"
ExecStartPost=-/bin/sh -c '/usr/bin/etcdctl set /{{parent}}/watched "$(date +%s%N)"'
ExecStop=/usr/bin/etcdctl rm /{{parent}}/{{service}}/services/%H_{{port}}

[Install]
WantedBy=multi-user.target
```
* requires etcd
* Publishes service's info into etcd every 45 seconds with a 60 second duration
* Deletes service info from etcd on stop
* Is restarted if etcd or the service restarts

## prometheus
The prometheus playbook templates out the prometheus config and sets up the prometheus unit and route discovery

[roles/prometheus/tasks/main.yml](dist/ansible/roles/prometheus/tasks/main.yml)
```yml
# Ensure the prometheus directories are created
- name: ensure prometheus directory is present
  file:
    state: directory
    path: /var/prometheus
    
- name: ensure prometheus config directory is present
  file:
    state: directory
    path: /var/prometheus/config
    
- name: ensure prometheus data directory is present
  file:
    state: directory
    path: /var/prometheus/data

# template out the prometheus config
- name: prometheus/config template
  template:
    src: prometheus.yml
    dest: /var/prometheus/config/prometheus.yml
  register: prometheus_config

# template out the systemd prometheus.service unit
- name: prometheus.service template
  template:
    src: prometheus.service
    dest: /etc/systemd/system/prometheus.service
  register: prometheus_service_template
    
- name: start/restart prometheus.service if template or config changed
  systemd:
    daemon_reload: yes
    enabled: yes
    state: restarted
    name: prometheus.service
  when: (prometheus_service_template | changed) or (prometheus_config | changed)
  
- name: ensure prometheus.service is started, even if the template or config didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: prometheus.service
  when: not ((prometheus_service_template | changed) or (prometheus_config | changed))
```

### prometheus role dependencies
[roles/prometheus/meta/main.yml](dist/ansible/roles/prometheus/meta/main.yml)
```yaml
---
dependencies:
  - { role: discovery, parent: 'route_discovery', service: 'prometheus', port: "{{ports['prometheus']}}", service_properties: {private: 'true'} }
```

### prometheus config template

[roles/prometheus/templates/prometheus.yml](dist/ansible/roles/prometheus/templates/prometheus.yml)
```yaml
global:
  scrape_interval:     15s # By default, scrape targets every 15 seconds.

  # Attach these labels to any time series or alerts when communicating with
  # external systems (federation, remote storage, Alertmanager).
  external_labels:
    monitor: 'codelab-monitor'

# A scrape configuration containing exactly one endpoint to scrape:
# Here it's Prometheus itself.
scrape_configs:
  # The job name is added as a label `job=<job_name>` to any timeseries scraped from this config.
  - job_name: 'prometheus'

    # Override the global default and scrape targets from this job every 5 seconds.
    scrape_interval: 5s

    # Prometheus sets its app context in response to setting web.external-url
    metrics_path: /prometheus/metrics
    
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'etcd'
    static_configs:
      - targets: [{% for host in groups['all'] | difference(['localhost']) %}'{{hostvars[host][internal_ip_name]}}:2379'{% if not loop.last %},{% endif %}{% endfor %} ]

  - job_name: 'nginx'
    static_configs:
      - targets: [{% for host in groups['frontend'] %}'{{hostvars[host][internal_ip_name]}}:9145'{% if not loop.last %},{% endif %}{% endfor %} ]

  - job_name: 'node_exporter'
    static_configs:
      - targets: [{% for host in groups['all'] | difference(['localhost']) %}'{{hostvars[host][internal_ip_name]}}:9100'{% if not loop.last %},{% endif %}{% endfor %} ]

```

### prometheus systemd service unit template

[roles/prometheus/templates/prometheus.service](dist/ansible/roles/prometheus/templates/prometheus.service)
```yaml
[Unit]
Description=Prometheus
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-prometheus:{{prometheus_version}}
ExecStartPre=-/usr/bin/docker rm prometheus
ExecStart=/usr/bin/docker run --name prometheus -p 9090:9090 \
-v /var/prometheus:/var/prometheus \
chadautry/wac-prometheus:{{prometheus_version}} \
--web.external-url https://{{domain_name}}/prometheus
Restart=always

[Install]
WantedBy=multi-user.target
```
* requires docker
* Starts a customized prometheus docker container
    * Version comes from variables
    * Takes config from local drive
    * Saves data to local drive

## grafana
The grafana playbook templates out the grafana config and sets up the grafana unit and route discovery

[roles/grafana/tasks/main.yml](dist/ansible/roles/grafana/tasks/main.yml)
```yml
# Ensure the grafana directories are created
- name: ensure grafana directory is present
  file:
    state: directory
    path: /var/grafana
    
- name: ensure /var/grafana/config is present
  file:
    state: directory
    path: /var/grafana/config

- name: ensure /var/grafana/provisioning is present
  file:
    state: directory
    path: /var/grafana/provisioning

- name: ensure /var/grafana/provisioning/datasources is present
  file:
    state: directory
    path: /var/grafana/provisioning/datasources

- name: ensure /var/grafana/provisioning/dashboards is present
  file:
    state: directory
    path: /var/grafana/provisioning/dashboards

# template out the grafana config
- name: grafana config template
  template:
    src: config.ini
    dest: /var/grafana/config/config.ini
  register: grafana_config

# template out the prometheus datasource
- name: grafana config template
  template:
    src: datasource.yml
    dest: /var/grafana/provisioning/datasources/datasource.yml
  register: grafana_datasource

# template out the systemd grafana.service unit
- name: grafana.service template
  template:
    src: grafana.service
    dest: /etc/systemd/system/grafana.service
  register: grafana_service_template
    
- name: start/restart grafana.service if template, config, or datasource changed
  systemd:
    daemon_reload: yes
    enabled: yes
    state: restarted
    name: grafana.service
  when: (grafana_service_template | changed) or (grafana_config | changed) or (grafana_datasource | changed)
  
- name: ensure grafana.service is started, even if the template or config didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: grafana.service
  when: not ((grafana_service_template | changed) or (grafana_config | changed) or (grafana_datasource | changed))
```

### grafana role dependencies
[roles/grafana/meta/main.yml](dist/ansible/roles/grafana/meta/main.yml)
```yaml
---
dependencies:
  - { role: discovery, parent: 'route_discovery', service: 'grafana', port: {{ports['grafana']}}, service_properties: {strip: 'true', private: 'true'} }
```

### grafana datasource template

[roles/grafana/templates/datasource.yml](dist/ansible/roles/grafana/templates/datasource.yml)
```yaml
datasources:
-  access: 'proxy'
   editable: true
   is_default: true
   name: 'prom1'
   org_id: 1
   type: 'prometheus'
   url: 'http://{{internal_ip_name}}:9090' 
   version: 1

```

### grafana config template

[roles/grafana/templates/config.ini](dist/ansible/roles/grafana/templates/config.ini)
```ini
[paths]
provisioning = /var/grafana/provisioning

[server]
domain = {{domain_name}}
root_url = %(protocol)s://%(domain)s:%(http_port)s/grafana/

[auth.proxy]
enabled = true
header_name = X-WEBAUTH-USER
header_property = username
auto_sign_up = true
```

### grafana systemd service unit template

[roles/grafana/templates/grafana.service](dist/ansible/roles/grafana/templates/grafana.service)
```yaml
[Unit]
Description=Grafana
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-grafana:{{grafana_version}}
ExecStartPre=-/usr/bin/docker rm grafana
ExecStart=/usr/bin/docker run --name grafana -p 3000:3000 \
-v /var/grafana:/var/grafana \
chadautry/wac-grafana:{{grafana_version}} -config /var/grafana/config/config.ini
Restart=always

[Install]
WantedBy=multi-user.target
```
* requires docker
* Starts a customized grafana docker container
    * Version comes from variables
    * Takes config from local drive
    * Saves data to local drive

## prometheus/node_exporter
Deploys or redeploys the prometheus/node_exporter instance on a host.

[roles/prometheus-node-exporter/tasks/main.yml](dist/ansible/roles/prometheus-node-exporter/tasks/main.yml)
```yml
# template out the systemd prometheus-node-exporter.service unit on the etcd hosts
- name: etcd template
  template:
    src: prometheus-node-exporter.service
    dest: /etc/systemd/system/prometheus-node-exporter.service
  register: node_exporter_template

- name: start/restart the prometheus-node-exporter.service if template changed
  systemd:
    daemon_reload: yes
    enabled: yes
    state: restarted
    name: prometheus-node-exporter.service
  when: node_exporter_template | changed
  
- name: Ensure prometheus-node-exporter.service is started, even if the template didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: prometheus-node-exporter.service
  when: not (node_exporter_template | changed)
```

### prometheus/node_exporter systemd unit template
[roles/prometheus-node-exporter/templates/prometheus-node-exporter.service](dist/ansible/roles/prometheus-node-exporter/templates/prometheus-node-exporter.service)
```yaml
[Unit]
Description=etcd
# Dependencies
Requires=docker.service

# Ordering
After=docker.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-prometheus-node_exporter:{{node_exporter_version}}
ExecStartPre=-/usr/bin/docker rm node_exporter
ExecStart=/usr/bin/docker run --name node_exporter -p 9100:9100 -v "/proc:/host/proc" \
-v "/sys:/host/sys" -v "/:/rootfs" --net="host" chadautry/wac-prometheus-node_exporter:{{node_exporter_version}}

Restart=always

[Install]
WantedBy=multi-user.target
````
* requires docker
* takes version from node_exporter_version variable

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
- include: route-discovery-watcher.yml

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
    enabled: yes
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
    enabled: yes
    state: restarted
    name: nginx.service
  when: nginx_template | changed
  
- name: Ensure nginx.service is started, even if the template didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: nginx.service
  when: not (nginx_template | changed)
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
ExecStart=/usr/bin/docker run --name nginx -p 80:80 -p 443:443 -p 9145:9145 \
-v /var/www:/usr/share/nginx/html:ro -v /var/ssl:/etc/nginx/ssl:ro \
-v /var/nginx:/usr/var/nginx:ro \
chadautry/wac-nginx:{{nginx_version}}
Restart=always

[Install]
WantedBy=multi-user.target
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

[Install]
WantedBy=multi-user.target
```
* Watches config file
* Watches the (last copied) SSL cert file
* Automatically calls nginx-reload.service on change (because of matching unit name)

### nginx route discovery
Sets a watch on the backend discovery location, and when it changes templates out the nginx conf

#### route-discovery-watcher task include
TODO Why isn't this a part of the nginx task?
[roles/frontend/tasks/route-discovery-watcher.yml](dist/ansible/roles/frontend/tasks/route-discovery-watcher.yml)
```yml
# template out the systemd service unit
- name: route-discovery-watcher.service template
  template:
    src: route-discovery-watcher.service
    dest: /etc/systemd/system/route-discovery-watcher.service
  register: route_discovery_watcher_template
    
- name: start/restart the service if template changed
  systemd:
    daemon_reload: yes
    enabled: yes
    state: restarted
    name: route-discovery-watcher.service
  when: route_discovery_watcher_template | changed
  
- name: Ensure the service is started, even if the template didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: route-discovery-watcher.service
  when: not (route_discovery_watcher_template | changed)
```

#### route-discovery-watcher systemd unit template
[roles/frontend/templates/route-discovery-watcher.service](dist/ansible/roles/frontend/templates/route-discovery-watcher.service)
```yaml
[Unit]
Description=Watches for nginx routes
# Dependencies
Requires=etcd.service

# Ordering
After=etcd.service

# Restart when dependency restarts
PartOf=etcd.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-nginx-config-templater:{{nginx_config_templater_version}}
ExecStartPre=-/usr/bin/docker rm nginx-templater
ExecStartPre=-/bin/sh -c '/usr/bin/etcdctl mk /route_discovery/watched "$(date +%s%N)"'
ExecStart=/usr/bin/etcdctl watch /discovery/watched 
ExecStartPost=-/usr/bin/docker run --name nginx-templater --net host \
-v /var/nginx:/usr/var/nginx -v /var/ssl:/etc/nginx/ssl:ro \
chadautry/wac-nginx-config-templater:{{nginx_config_templater_version}}
Restart=always

[Install]
WantedBy=multi-user.target
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
    enabled: yes
    state: restarted
    name: certificate-sync.service
  when: certificate_sync_template | changed

- name: Ensure certificate-sync.service is started, even if the template didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: certificate-sync.service
  when: not (certificate_sync_template | changed)

# template out the systemd acme-response-watcher.service unit
- name: acme-response-watcher.service template
  template:
    src: acme-response-watcher.service
    dest: /etc/systemd/system/acme-response-watcher.service
  register: acme_response_watcher_template

- name: start/restart the acme-response-watcher.service if template changed
  systemd:
    daemon_reload: yes
    enabled: yes
    state: restarted
    name: acme-response-watcher.service
  when: acme_response_watcher_template | changed

- name: Ensure acme-response-watcher.service is started, even if the template didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: acme-response-watcher.service
  when: not (acme_response_watcher_template | changed)
 
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
    enabled: yes
    state: restarted
    name: letsencrypt-renewal.timer
  when: letsencrpyt_renewal_template | changed

- name: Ensure letsencrypt-renewal.timer is started, even if the template didn't change
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: letsencrypt-renewal.timer
  when: not (letsencrpyt_renewal_template | changed)

- name: Execute the renewal oneshot on deploy
  systemd:
    daemon_reload: yes
    enabled: no
    state: started
    name: letsencrypt-renewal.service
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

[Install]
WantedBy=multi-user.target
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

[Install]
WantedBy=multi-user.target
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

[roles/frontend/templates/letsencrypt-renewal.timer](dist/ansible/roles/frontend/templates/letsencrypt-renewal.timer)
```yaml
[Unit]
Description=Letsencrpyt renewal timer

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=1800

[Install]
WantedBy=multi-user.target
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
  tags: frontend_application

- name: Remove old webapp staging
  file:
    path: /var/staging/webapp
    state: absent
  tags: frontend_application

- name: Ensure remote staging dir exists
  file:
    path: /var/staging
    state: directory
  tags: frontend_application

- name: Transfer and unpack webapp to staging
  unarchive:
    src: "{{controller_src_staging}}/frontendsrc.tgz"
    dest: /var/staging
  tags: frontend_application
    
- name: Pull alpine-rsync image
  command: /usr/bin/docker pull chadautry/alpine-rsync:{{rsync_version}}
  tags: frontend_application
   
- name: sync staging and /var/www
  command: /usr/bin/docker run -v /var/staging:/var/staging -v /var/www:/var/www --rm chadautry/alpine-rsync:{{rsync_version}} -a /var/staging/webapp/ /var/www
  tags: frontend_application
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
    enabled: yes
    state: restarted
    name: "{{identifier}}_nodejs.service"
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
  {% for key in node_config[identifier] %}{{key|upper}}: '{{node_config[identifier][key]}}'{% if not loop.last %},{% endif %}{% endfor %}
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
ExecStartPre=-/usr/bin/docker rm -f {{identifier}}-node-container
ExecStart=/usr/bin/docker run --name {{identifier}}-node-container -p {{nodejs_port}}:80 \
-v /var/nodejs/{{identifier}}:/app:ro \
chadautry/wac-node '%H'
ExecStop=-/usr/bin/docker stop {{identifier}}-node-container
Restart=always

[Install]
WantedBy=multi-user.target
```
* requires docker
* Starts a customized nodejs docker container
    * Takes the app and configuration from local drive

## RethinkDB
The RethinkDB role is used to install/update the database and its configurations

[roles/rethinkdb/tasks/main.yml](dist/ansible/roles/rethinkdb/tasks/main.yml)
```yml  
# Ensure the database directory is present
- name: ensure database directory is present
  file:
    state: directory
    path: /var/rethinkdb

# Template out the database config
- name: rethinkdb.conf template
  template:
    src: rethinkdb.conf
    dest: /var/rethinkdb/rethinkdb.conf

# Template out the rethinkdb systemd unit
- name: rethinkdb.service template
  template:
    src: rethinkdb.service
    dest: /etc/systemd/system/rethinkdb.service

# Start the RethinkDB server, note doesn't need to be restarted even if config changed (new instances will connect to old)
- name: Ensure RethinkDB is started
  systemd:
    daemon_reload: yes
    enabled: yes
    state: started
    name: rethinkdb.service
```

### rethinkdb role dependencies
[roles/grafana/meta/main.yml](dist/ansible/roles/grafana/meta/main.yml)
```yaml
---
dependencies:
  - { role: discovery, when: not proxy_rethinkdb, parent: 'route_discovery', service: 'rethinkdb', port: "{{ports['rethinkdb_admin']}}", service_properties: {strip: 'true', private: 'true'} }
```

### rethinkd.conf template
The template for the configuration file. Contains the list of other hosts to connect to. If not a proxy, contains the hosts cannonical address other instances connect to it at
[roles/rethinkdb/templates/rethinkdb.conf](dist/ansible/roles/rethinkdb/templates/rethinkdb.conf)
```
runuser=root
rungroup=root
pid-file=/usr/var/rethinkdb/pid_file
directory=/usr/var/rethinkdb/data
bind=all

{% if not proxy_rethinkdb %}
canonical-address={{hostvars[inventory_hostname][internal_ip_name]}}:29015
{% endif %}

{% for host in groups['rethinkdb']  %}
{% if hostvars[host][internal_ip_name] != hostvars[inventory_hostname][internal_ip_name] %}
join={{hostvars[host][internal_ip_name]}}:29015
{% endif %}
{% endfor %}
```

### RethinkDB systemd unit template
[roles/rethinkdb/templates/rethinkdb.service](dist/ansible/roles/rethinkdb/templates/rethinkdb.service)
```yaml
[Unit]
Description=RethinkDB
# Dependencies
Requires=docker.service

# Ordering
After=docker.service
After=etcd2.service

[Service]
ExecStartPre=-/usr/bin/docker pull chadautry/wac-rethinkdb:{{rethinkdb_version}}
ExecStartPre=-/usr/bin/docker rm -f rethinkdb
ExecStartPre=-/usr/bin/rm /var/rethinkdb/pid_file
ExecStart=/usr/bin/docker run --name rethinkdb \
-v /var/rethinkdb:/usr/var/rethinkdb \
-p 29015:29015 -p28015:28015 -p 8081:8080 \
chadautry/wac-rethinkdb:{{rethinkdb_version}} {% if proxy_rethinkdb %}proxy{% endif %} --config-file /usr/var/rethinkdb/rethinkdb.conf
Restart=always

[Install]
WantedBy=multi-user.target
```

* requires docker
* Pulls the image
* Removes the container
* Starts a rethinkdb container
  * Conditionally started in proxy mode based on role parameter
* HTTP shifted to 8081 so it won't conflict with nginx if colocated

### RethinkDB route-publishing systemd unit template
Publishes the rethinkdb host into etcd at an expected path for the frontend to route to

[roles/rethinkdb/templates/rethinkdb-route-publishing.service](dist/ansible/roles/rethinkdb/templates/rethinkdb-route-publishing.service)
```yaml
[Unit]
Description=RethinkDB Route Publishing
# Dependencies
Requires=etcd.service
Requires=rethinkdb.service

# Ordering
After=etcd.service
After=rethinkdb.service

# Restart when dependency restarts
PartOf=etcd.service
PartOf=rethinkdb.service

[Service]
ExecStart=/bin/sh -c "while true; do etcdctl set /discovery/rethinkdb/hosts/%H/host '%H' --ttl 60; \
                      etcdctl set /discovery/rethinkdb/hosts/%H/port 8081 --ttl 60; \
                      etcdctl set /discovery/rethinkdb/strip 'true' --ttl 60; \
                      etcdctl set /discovery/rethinkdb/private 'true' --ttl 60; \
                      sleep 45; \
                      done"
ExecStartPost=-/bin/sh -c '/usr/bin/etcdctl set /discovery/watched "$(date +%s%N)"'
ExecStop=/usr/bin/etcdctl rm /discovery/rethinkdb/hosts/%H

[Install]
WantedBy=multi-user.target
```
* requires etcd
* Publishes host into etcd every 45 seconds with a 60 second duration
* Deletes host from etcd on stop
* Is restarted if etcd or rethinkdb restarts
