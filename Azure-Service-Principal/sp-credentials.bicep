@secure()
param clientId string

@secure()
param clientSecret string
@secure()
param tenantId string

output clientId string = clientId
output clientSecret string = clientSecret
output tenantId string = tenantId
