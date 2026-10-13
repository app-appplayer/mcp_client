// Deliberately imports nothing from mcp_client: a consumer library that
// receives a result from elsewhere must still read the common fields
// (members, not extensions, which would need the import).
String firstText(dynamic result) => result.contents.first.text as String;

String? firstTextTyped(List<Object> contents) => (contents.first as dynamic).text as String?;
