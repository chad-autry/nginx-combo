module.exports = {
  PORT: 80,
{%- for key in node_config[identifier] %}
  {{key}}: '{{node_config[identifier][key]}}'{% if not loop.last %},{% endif %}
{%- endfor %}
};
