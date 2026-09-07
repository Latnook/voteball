output "endpoint" {
  description = "RDS endpoint host (becomes DB_HOST in the app ConfigMap)."
  value       = aws_db_instance.app.address
}
