class ApiConfig {
  ApiConfig._();

  static const String websiteBaseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'https://gptminpro.online',
  );

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://gptminpro.online/api/v1/',
  );

  //Sample user for login
  //username:demo.user02@tlstore.test
  //password:meandmyson
  //NOTE: Use the above to access the live api server

  static Uri endpoint(String path) {
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
    return base.resolve(path);
  }

  static bool isAppWebsiteLink(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;

    final configuredHosts = <String>{
      Uri.parse(websiteBaseUrl).host.toLowerCase(),
      Uri.parse(baseUrl).host.toLowerCase(),
    }..removeWhere((host) => host.isEmpty);

    return configuredHosts.contains(uri.host.toLowerCase());
  }
}
