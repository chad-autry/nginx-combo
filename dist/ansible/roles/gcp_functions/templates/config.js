module.exports = {
  {% for key in item.props %}{{key|upper}}: '{{item.props[key]}}'{% if not loop.last %},{% endif %}{% endfor %}
};
