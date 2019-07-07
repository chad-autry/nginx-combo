module.exports = {
  {% for key in gcp_functions[item][props] %}{{key|upper}}: '{{gcp_functions[item][props][key]}}'{% if not loop.last %},{% endif %}{% endfor %}
};
