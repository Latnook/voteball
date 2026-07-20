output "instance_id" {
  description = "For `aws ec2 stop-instances --instance-ids <id>` between working sessions."
  value       = aws_instance.jenkins.id
}

output "jenkins_public_ip" {
  description = "Elastic IP. Stable across stop/start."
  value       = aws_eip.jenkins.public_ip
}

output "ssh_tunnel_command" {
  description = "Run this, then browse http://localhost:8080. The UI is not publicly reachable."
  value       = "ssh -i ~/.ssh/${var.cluster_name}-jenkins.pem -L 8080:localhost:8080 ec2-user@${aws_eip.jenkins.public_ip}"
}

output "webhook_url" {
  description = "Paste into GitHub > Settings > Webhooks. The trailing slash is required."
  value       = "http://${aws_eip.jenkins.public_ip}:8080/github-webhook/"
}
