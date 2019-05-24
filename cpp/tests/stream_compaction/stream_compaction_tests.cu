/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <stream_compaction.hpp>
#include <table.hpp>

#include <utilities/error_utils.hpp>

#include <tests/utilities/column_wrapper.cuh>
#include <tests/utilities/cudf_test_fixtures.h>

struct ApplyBooleanMaskErrorTest : GdfTest {};

// Test ill-formed inputs

TEST_F(ApplyBooleanMaskErrorTest, NullPtrs)
{
  constexpr gdf_size_type column_size{1000};

  gdf_column bad_input, bad_mask;
  gdf_column_view(&bad_input, 0, 0, 0, GDF_INT32);
  gdf_column_view(&bad_mask,  0, 0, 0, GDF_BOOL8);

  cudf::test::column_wrapper<int32_t> source{column_size};
  cudf::test::column_wrapper<cudf::bool8> mask{column_size};

  CUDF_EXPECT_NO_THROW(cudf::apply_boolean_mask(bad_input, mask));

  bad_input.valid = reinterpret_cast<gdf_valid_type*>(0x0badf00d);
  bad_input.null_count = 2;
  bad_input.size = column_size; 
  // nonzero, with non-null valid mask, so non-null input expected
  CUDF_EXPECT_THROW_MESSAGE(cudf::apply_boolean_mask(bad_input, mask),
                            "Null input data");

  CUDF_EXPECT_THROW_MESSAGE(cudf::apply_boolean_mask(source, bad_mask),
                            "Null boolean_mask");
}

TEST_F(ApplyBooleanMaskErrorTest, SizeMismatch)
{
  constexpr gdf_size_type column_size{1000};
  constexpr gdf_size_type mask_size{500};

  cudf::test::column_wrapper<int32_t> source{column_size};
  cudf::test::column_wrapper<cudf::bool8> mask{mask_size};
             
  CUDF_EXPECT_THROW_MESSAGE(cudf::apply_boolean_mask(source, mask), 
                            "Column size mismatch");
}

TEST_F(ApplyBooleanMaskErrorTest, NonBooleanMask)
{
  constexpr gdf_size_type column_size{1000};

  cudf::test::column_wrapper<int32_t> source{column_size};
  cudf::test::column_wrapper<float> nonbool_mask{column_size};
             
  CUDF_EXPECT_THROW_MESSAGE(cudf::apply_boolean_mask(source, nonbool_mask), 
                            "Mask must be Boolean type");

  cudf::test::column_wrapper<cudf::bool8> bool_mask{column_size, true};
  EXPECT_NO_THROW(cudf::apply_boolean_mask(source, bool_mask));
}

template <typename T>
struct ApplyBooleanMaskTest : GdfTest {};

using test_types =
    ::testing::Types<int8_t, int16_t, int32_t, int64_t, float, double>;
TYPED_TEST_CASE(ApplyBooleanMaskTest, test_types);

// Test computation

/*
 * Runs apply_boolean_mask checking for errors, and compares the result column 
 * to the specified expected result column.
 */
template <typename T>
void BooleanMaskTest(cudf::test::column_wrapper<T> const& source,
                     cudf::test::column_wrapper<cudf::bool8> const& mask,
                     cudf::test::column_wrapper<T> const& expected)
{
  gdf_column result;
  EXPECT_NO_THROW(result = cudf::apply_boolean_mask(source, mask));

  EXPECT_TRUE(expected == result);

  if (!(expected == result)) {
    std::cout << "expected\n";
    expected.print();
    std::cout << expected.get()->null_count << "\n";
    std::cout << "result\n";
    print_gdf_column(&result);
    std::cout << result.null_count << "\n";
  }

  gdf_column_free(&result);
}

constexpr gdf_size_type column_size{1000000};

TYPED_TEST(ApplyBooleanMaskTest, Identity)
{
  BooleanMaskTest<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }},
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return true; }},
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }});
}

TYPED_TEST(ApplyBooleanMaskTest, MaskAllNullOrFalse)
{
  cudf::test::column_wrapper<TypeParam> input{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<TypeParam> expected{0, false};
  
  BooleanMaskTest<TypeParam>(input, 
    cudf::test::column_wrapper<cudf::bool8>{column_size, 
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return false; }},
    expected);
  
  BooleanMaskTest<TypeParam>(input, 
    cudf::test::column_wrapper<cudf::bool8>{column_size, 
      [](gdf_index_type row) { return cudf::bool8{false}; },
      [](gdf_index_type row) { return true; }},
    expected);
}

TYPED_TEST(ApplyBooleanMaskTest, MaskEvensFalseOrNull)
{
  // mix it up a bit by setting the input odd values to be null
  // Since the bool mask has even values null, the output
  // vector should have all values nulled

  cudf::test::column_wrapper<TypeParam> input{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return row % 2 == 0; }};
  cudf::test::column_wrapper<TypeParam> expected{column_size / 2,
      [](gdf_index_type row) { return 2 * row + 1;  },
      [](gdf_index_type row) { return false; }};
  
  BooleanMaskTest<TypeParam>(input,
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{row % 2 == 1}; },
      [](gdf_index_type row) { return true; }},
    expected);

  BooleanMaskTest<TypeParam>(input,
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return row % 2 == 1; }},
    expected);
}

TYPED_TEST(ApplyBooleanMaskTest, NonalignedGap)
{
  const int start{1}, end{column_size / 4};

  BooleanMaskTest<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }},
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{(row < start) || (row >= end)}; },
      [](gdf_index_type row) { return true; }},
    cudf::test::column_wrapper<TypeParam>{column_size - (end - start),
      [](gdf_index_type row) { return (row < start) ? row : row + end - start; },
      [&](gdf_index_type row) { return true; }});
}

TYPED_TEST(ApplyBooleanMaskTest, NoNullMask)
{
  std::vector<TypeParam> source(column_size, TypeParam{0});
  std::vector<TypeParam> expected(column_size / 2, TypeParam{0});
  std::iota(source.begin(), source.end(), TypeParam{0});
  std::generate(expected.begin(), expected.end(), 
                [n = -1] () mutable { return n+=2; });

  BooleanMaskTest<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{source},
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return row % 2 == 1; }},
    cudf::test::column_wrapper<TypeParam> {expected});
}

struct ApplyBooleanMaskTableTest : GdfTest {};

void BooleanMaskTableTest(cudf::table const &source,
                          cudf::test::column_wrapper<cudf::bool8> const &mask,
                          cudf::table &expected)
{
  cudf::table result;
  EXPECT_NO_THROW(result = cudf::apply_boolean_mask(source, mask));

  for (int c = 0; c < result.num_columns(); c++) {
    gdf_column *res = result.get_column(c);
    gdf_column *exp = result.get_column(c);
    EXPECT_TRUE(gdf_equal_columns(res, exp));
    
    if (!gdf_equal_columns(res, exp)) {
      std::cout << "expected\n";
      print_gdf_column(exp);
      std::cout << exp->null_count << "\n";
      std::cout << "result\n";
      print_gdf_column(res);
      std::cout << res->null_count << "\n";
    }

    gdf_column_free(res);
  }
}

TEST_F(ApplyBooleanMaskTableTest, Identity)
{
  cudf::test::column_wrapper<int32_t> int_column{
      column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<float> float_column{
      column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<cudf::bool8> bool_column{
      column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return true; }};

  cudf::test::column_wrapper<cudf::bool8> mask{
      column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return true; }};
    
  std::vector<gdf_column*> cols;
  cols.push_back(int_column.get());
  cols.push_back(float_column.get());
  cols.push_back(bool_column.get());
  cudf::table table_source(cols.data(), 3);
  cudf::table table_expected(cols.data(), 3);

  BooleanMaskTableTest(table_source, mask, table_expected);
}

TEST_F(ApplyBooleanMaskTableTest, MaskAllNullOrFalse)
{
  cudf::test::column_wrapper<int32_t> int_column{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<float> float_column{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<cudf::bool8> bool_column{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return true; }};
    
  std::vector<gdf_column*> cols;
  cols.push_back(int_column.get());
  cols.push_back(float_column.get());
  cols.push_back(bool_column.get());
  cudf::table table_source(cols.data(), 3);
  cudf::table table_expected(0, column_dtypes(table_source), true, false);

  BooleanMaskTableTest(table_source, 
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return false; }},
    table_expected);

  BooleanMaskTableTest(table_source, 
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{false}; },
      [](gdf_index_type row) { return true; }},
    table_expected);
}

TEST_F(ApplyBooleanMaskTableTest, MaskEvensFalseOrNull)
{
  cudf::test::column_wrapper<int32_t> int_column{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return row % 2 == 0; }};
  cudf::test::column_wrapper<float> float_column{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return row % 2 == 0; }};
  cudf::test::column_wrapper<cudf::bool8> bool_column{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return row % 2 == 0; }};

  std::vector<gdf_column*> cols;
  cols.push_back(int_column.get());
  cols.push_back(float_column.get());
  cols.push_back(bool_column.get());
  cudf::table table_source(cols.data(), 3);

  cudf::test::column_wrapper<int32_t> int_expected{column_size / 2,
      [](gdf_index_type row) { return 2 * row + 1;  },
      [](gdf_index_type row) { return false; }};
  cudf::test::column_wrapper<float> float_expected{column_size / 2,
      [](gdf_index_type row) { return 2 * row + 1;  },
      [](gdf_index_type row) { return false; }};
  cudf::test::column_wrapper<cudf::bool8> bool_expected{column_size / 2,
      [](gdf_index_type row) { return cudf::bool8{true};  },
      [](gdf_index_type row) { return false; }};
  
  std::vector<gdf_column*> cols_expected;
  cols_expected.push_back(int_expected.get());
  cols_expected.push_back(float_expected.get());
  cols_expected.push_back(bool_expected.get());
  cudf::table table_expected(cols_expected.data(), 3);

  BooleanMaskTableTest(table_source, 
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{row % 2 == 1}; },
      [](gdf_index_type row) { return true; }},
    table_expected);

  BooleanMaskTableTest(table_source, 
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return row % 2 == 1; }},
    table_expected);
}

TEST_F(ApplyBooleanMaskTableTest, NonalignedGap)
{
  const int start{1}, end{column_size / 4};

  cudf::test::column_wrapper<int32_t> int_column{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<float> float_column{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<cudf::bool8> bool_column{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return true; }};

  std::vector<gdf_column*> cols;
  cols.push_back(int_column.get());
  cols.push_back(float_column.get());
  cols.push_back(bool_column.get());
  cudf::table table_source(cols.data(), 3);

  cudf::test::column_wrapper<int32_t> int_expected{column_size - (end - start),
      [](gdf_index_type row) { return (row < start) ? row : row + end - start; },
      [&](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<float> float_expected{column_size - (end - start),
      [](gdf_index_type row) { return (row < start) ? row : row + end - start; },
      [&](gdf_index_type row) { return true; }};
  cudf::test::column_wrapper<cudf::bool8> bool_expected{column_size - (end - start),
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [&](gdf_index_type row) { return true; }};
  
  std::vector<gdf_column*> cols_expected;
  cols_expected.push_back(int_expected.get());
  cols_expected.push_back(float_expected.get());
  cols_expected.push_back(bool_expected.get());
  cudf::table table_expected(cols_expected.data(), 3);

  BooleanMaskTableTest(table_source, 
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{(row < start) || (row >= end)}; },
      [](gdf_index_type row) { return true; }},
    table_expected);
}

TEST_F(ApplyBooleanMaskTableTest, NoNullMask)
{
  std::vector<int32_t> int_source(column_size, int32_t{0});
  std::vector<float> float_source(column_size, float{0});
  std::vector<cudf::bool8> bool_source(column_size, cudf::true_v);
  std::vector<int32_t> int_expected(column_size / 2, int32_t{0});
  std::vector<float> float_expected(column_size / 2, float{0});
  std::vector<cudf::bool8> bool_expected(column_size / 2, cudf::true_v);
  std::iota(int_source.begin(), int_source.end(), int{0});
  std::iota(float_source.begin(), float_source.end(), float{0});
  std::generate(int_expected.begin(), int_expected.end(), 
                [n = -1] () mutable { return n+=2; });
  std::generate(float_expected.begin(), float_expected.end(), 
                [n = -1] () mutable { return n+=2; });
  
  std::vector<gdf_column*> cols;
  cols.push_back(cudf::test::column_wrapper<int32_t>{int_source}.get());
  cols.push_back(cudf::test::column_wrapper<float>{float_source}.get());
  cols.push_back(cudf::test::column_wrapper<cudf::bool8>{bool_source}.get());
  cudf::table table_source(cols.data(), 3);

  std::vector<gdf_column*> cols_exp;
  cols_exp.push_back(cudf::test::column_wrapper<int32_t>{int_expected}.get());
  cols_exp.push_back(cudf::test::column_wrapper<float>{float_expected}.get());
  cols_exp.push_back(cudf::test::column_wrapper<cudf::bool8>{bool_expected}.get());
  cudf::table table_expected(cols_exp.data(), 3);

  BooleanMaskTableTest(table_source,
    cudf::test::column_wrapper<cudf::bool8>{column_size,
      [](gdf_index_type row) { return cudf::bool8{true}; },
      [](gdf_index_type row) { return row % 2 == 1; }},
    table_expected);
}

struct DropNullsErrorTest : GdfTest {};

TEST_F(DropNullsErrorTest, EmptyInput)
{
  gdf_column bad_input;
  gdf_column_view(&bad_input, 0, 0, 0, GDF_INT32);

  // zero size, so expect no error, just empty output column
  gdf_column output;
  CUDF_EXPECT_NO_THROW(output = cudf::drop_nulls(bad_input));
  EXPECT_EQ(output.size, 0);
  EXPECT_EQ(output.null_count, 0);
  EXPECT_EQ(output.data, nullptr);
  EXPECT_EQ(output.valid, nullptr);

  bad_input.valid = reinterpret_cast<gdf_valid_type*>(0x0badf00d);
  bad_input.null_count = 1;
  bad_input.size = 2; 
  // nonzero, with non-null valid mask, so non-null input expected
  CUDF_EXPECT_THROW_MESSAGE(cudf::drop_nulls(bad_input), "Null input data");
}

/*
 * Runs drop_nulls checking for errors, and compares the result column 
 * to the specified expected result column.
 */
template <typename T>
void DropNulls(cudf::test::column_wrapper<T> source,
               cudf::test::column_wrapper<T> expected)
{
  gdf_column result;
  EXPECT_NO_THROW(result = cudf::drop_nulls(source));
  EXPECT_EQ(result.null_count, 0);
  EXPECT_TRUE(expected == result);

  /*if (!(expected == result)) {
    std::cout << "expected\n";
    expected.print();
    std::cout << expected.get()->null_count << "\n";
    std::cout << "result\n";
    print_gdf_column(&result);
    std::cout << result.null_count << "\n";
  }*/

  gdf_column_free(&result);
}

template <typename T>
struct DropNullsTest : GdfTest {};

TYPED_TEST_CASE(DropNullsTest, test_types);

TYPED_TEST(DropNullsTest, Identity)
{
  DropNulls<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }},
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return true; }});
}

TYPED_TEST(DropNullsTest, AllNull)
{
  DropNulls<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return false; }},
    cudf::test::column_wrapper<TypeParam>{0, false});
}

TYPED_TEST(DropNullsTest, EvensNull)
{
  DropNulls<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return row % 2 == 1; }},
    cudf::test::column_wrapper<TypeParam>{column_size / 2,
      [](gdf_index_type row) { return 2 * row + 1;  },
      [](gdf_index_type row) { return true; }});
}

TYPED_TEST(DropNullsTest, NonalignedGap)
{
  const int start{1}, end{column_size / 4};

  DropNulls<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{column_size,
      [](gdf_index_type row) { return row; },
      [](gdf_index_type row) { return (row < start) || (row >= end); }},
    cudf::test::column_wrapper<TypeParam>{column_size - (end - start),
      [](gdf_index_type row) { return (row < start) ? row : row + end - start; },
      [&](gdf_index_type row) { return true; }});
}

TYPED_TEST(DropNullsTest, NoNullMask)
{
  std::vector<TypeParam> source(column_size, TypeParam{0});
  std::vector<TypeParam> expected(column_size, TypeParam{0});
  std::iota(source.begin(), source.end(), TypeParam{0});
  std::iota(expected.begin(), expected.end(), TypeParam{0});

  DropNulls<TypeParam>(
    cudf::test::column_wrapper<TypeParam>{source},
    cudf::test::column_wrapper<TypeParam> {expected});
}