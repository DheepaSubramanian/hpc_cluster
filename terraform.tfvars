# Terraform variable values for this stack.
#
# Define Linux user accounts to be created on BOTH:
# - the DCV/login node (main.tf user_data)
# - PCS compute nodes (launch_template.tf user_data)
#
# Format: username = uid
# - usernames must be lowercase Linux names
# - uids must be unique and between 2000 and 59999
#
# Example:
# cluster_users = {
#   alice = 2001
#   bob   = 2002
# }

cluster_users = {dheepa = 2001}
