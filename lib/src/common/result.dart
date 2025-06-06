import 'package:meta/meta.dart';

/// A sealed class representing the result of an operation that can succeed or fail
@immutable
sealed class Result<T, E extends Object> {
  const Result();

  /// Creates a successful result with the given value
  const factory Result.success(T value) = Success<T, E>;

  /// Creates a failed result with the given error
  const factory Result.failure(E error) = Failure<T, E>;

  /// Returns true if this result represents a success
  bool get isSuccess => switch (this) {
    Success() => true,
    Failure() => false,
  };

  /// Returns true if this result represents a failure
  bool get isFailure => !isSuccess;

  /// Returns the success value if this is a success, or null if this is a failure
  T? get successOrNull => switch (this) {
    Success(value: final value) => value,
    Failure() => null,
  };

  /// Returns the error if this is a failure, or null if this is a success
  E? get failureOrNull => switch (this) {
    Success() => null,
    Failure(error: final error) => error,
  };

  /// Returns the success value if this is a success, or throws the error if this is a failure
  T get() => switch (this) {
    Success(value: final value) => value,
    Failure(error: final error) => throw error,
  };

  /// Returns the success value if this is a success, or the given default value if this is a failure
  T getOrElse(T defaultValue) => switch (this) {
    Success(value: final value) => value,
    Failure() => defaultValue,
  };

  /// Returns the success value if this is a success, or null if this is a failure
  T? getOrNull() => successOrNull;

  /// Returns the error if this is a failure, or null if this is a success
  E? errorOrNull() => failureOrNull;

  /// Maps the success value using the given function, preserving failures
  Result<U, E> map<U>(U Function(T) mapper) => switch (this) {
    Success(value: final value) => Result.success(mapper(value)),
    Failure(error: final error) => Result.failure(error),
  };

  /// Maps the error using the given function, preserving successes
  Result<T, F> mapError<F extends Object>(F Function(E) mapper) =>
      switch (this) {
        Success(value: final value) => Result.success(value),
        Failure(error: final error) => Result.failure(mapper(error)),
      };

  /// Flat maps the success value using the given function, preserving failures
  Result<U, E> flatMap<U>(Result<U, E> Function(T) mapper) => switch (this) {
    Success(value: final value) => mapper(value),
    Failure(error: final error) => Result.failure(error),
  };

  /// Executes the given function with the success value if this is a success
  Result<T, E> onSuccess(void Function(T) action) {
    if (this case Success(value: final value)) {
      action(value);
    }
    return this;
  }

  /// Executes the given function with the error if this is a failure
  Result<T, E> onFailure(void Function(E) action) {
    if (this case Failure(error: final error)) {
      action(error);
    }
    return this;
  }

  /// Folds this result into a single value using the appropriate function
  U fold<U>(U Function(T) onSuccess, U Function(E) onFailure) => switch (this) {
    Success(value: final value) => onSuccess(value),
    Failure(error: final error) => onFailure(error),
  };
}

/// Represents a successful result
@immutable
final class Success<T, E extends Object> extends Result<T, E> {
  /// The success value
  final T value;

  const Success(this.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Success<T, E> && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Success($value)';
}

/// Represents a failed result
@immutable
final class Failure<T, E extends Object> extends Result<T, E> {
  /// The error
  final E error;

  const Failure(this.error);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Failure<T, E> && error == other.error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'Failure($error)';
}

/// Extension methods for `Future<Result>`
extension FutureResultExtensions<T, E extends Object> on Future<Result<T, E>> {
  /// Maps the success value asynchronously
  Future<Result<U, E>> mapAsync<U>(Future<U> Function(T) mapper) async {
    final result = await this;
    return switch (result) {
      Success(value: final value) => Result.success(await mapper(value)),
      Failure(error: final error) => Result.failure(error),
    };
  }

  /// Flat maps the success value asynchronously
  Future<Result<U, E>> flatMapAsync<U>(
    Future<Result<U, E>> Function(T) mapper,
  ) async {
    final result = await this;
    return switch (result) {
      Success(value: final value) => mapper(value),
      Failure(error: final error) => Result.failure(error),
    };
  }
}

/// Utility functions for working with Results
class Results {
  /// Converts a nullable value to a Result
  static Result<T, String> fromNullable<T>(T? value, String error) {
    return value != null ? Result.success(value) : Result.failure(error);
  }

  /// Executes a function and catches any exceptions, returning them as failures
  static Result<T, Exception> catching<T>(T Function() action) {
    try {
      return Result.success(action());
    } on Exception catch (e) {
      return Result.failure(e);
    }
  }

  /// Executes an async function and catches any exceptions, returning them as failures
  static Future<Result<T, Exception>> catchingAsync<T>(
    Future<T> Function() action,
  ) async {
    try {
      return Result.success(await action());
    } on Exception catch (e) {
      return Result.failure(e);
    }
  }

  /// Combines multiple Results into a single Result containing a list
  static Result<List<T>, E> combine<T, E extends Object>(
    List<Result<T, E>> results,
  ) {
    final values = <T>[];
    for (final result in results) {
      switch (result) {
        case Success(value: final value):
          values.add(value);
        case Failure(error: final error):
          return Result.failure(error);
      }
    }
    return Result.success(values);
  }
}
