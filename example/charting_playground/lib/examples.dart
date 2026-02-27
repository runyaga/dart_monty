/// Pre-built Python examples demonstrating the DataFrame + Chart API.
class Example {
  const Example({required this.name, required this.code});

  final String name;
  final String code;
}

const examples = <Example>[
  Example(
    name: 'Quick Start — Line Chart',
    code: '''
df = df_create([
  {"month": "Jan", "sales": 100},
  {"month": "Feb", "sales": 150},
  {"month": "Mar", "sales": 120},
  {"month": "Apr", "sales": 180},
  {"month": "May", "sales": 160},
  {"month": "Jun", "sales": 200},
], ["month", "sales"])

chart_line(df, "month", "sales", title="Monthly Sales")
chart_add_legend(1)
chart_add_tooltip(1)
df_describe(df)
''',
  ),
  Example(
    name: 'Scatter Plot with Groups',
    code: '''
csv = """x,y,group
1,2,A
2,4,A
3,3,A
4,6,B
5,5,B
6,8,B
7,7,C
8,9,C
9,8,C"""

df = df_from_csv(csv)
chart_scatter(df, "x", "y", color="group", title="Grouped Scatter")
chart_add_legend(1)
chart_add_tooltip(1)
''',
  ),
  Example(
    name: 'Bar Chart from Aggregation',
    code: '''
csv = """name,dept,salary
Alice,Engineering,95000
Bob,Sales,72000
Carol,Engineering,88000
Dave,Sales,79000
Eve,Marketing,68000
Frank,Engineering,92000
Grace,Marketing,71000"""

df = df_from_csv(csv)
grouped = df_group_agg(df, ["dept"], {"salary": "mean"})
sorted_df = df_sort(grouped, "salary", False)
chart_bar(sorted_df, "dept", "salary", title="Average Salary by Department")
chart_add_tooltip(1)
df_to_list(sorted_df)
''',
  ),
  Example(
    name: 'Pie Chart',
    code: '''
df = df_create([
  {"category": "Electronics", "revenue": 45000},
  {"category": "Clothing", "revenue": 32000},
  {"category": "Food", "revenue": 28000},
  {"category": "Books", "revenue": 15000},
  {"category": "Sports", "revenue": 20000},
])

chart_pie(df, "category", "revenue", title="Revenue by Category")
chart_add_legend(1)
chart_add_tooltip(1)
''',
  ),
  Example(
    name: 'Area Chart — Multi-series',
    code: '''
csv = """month,product,units
Jan,Widget,120
Feb,Widget,135
Mar,Widget,150
Apr,Widget,140
May,Widget,170
Jun,Widget,190
Jan,Gadget,80
Feb,Gadget,95
Mar,Gadget,110
Apr,Gadget,105
May,Gadget,130
Jun,Gadget,145"""

df = df_from_csv(csv)
chart_area(df, "month", "units", color="product", title="Units Sold")
chart_add_legend(1)
chart_add_tooltip(1)
''',
  ),
  Example(
    name: 'Data Pipeline',
    code: '''
# Create raw data
csv = """date,region,product,amount
2024-Q1,North,A,100
2024-Q1,North,B,80
2024-Q1,South,A,90
2024-Q1,South,B,110
2024-Q2,North,A,120
2024-Q2,North,B,95
2024-Q2,South,A,85
2024-Q2,South,B,130
2024-Q3,North,A,140
2024-Q3,North,B,100
2024-Q3,South,A,95
2024-Q3,South,B,125"""

df = df_from_csv(csv)

# Filter to product A only
product_a = df_filter(df, "product", "==", "A")

# Sort by date
sorted_df = df_sort(product_a, "date")

# Chart it
chart_bar(sorted_df, "date", "amount", color="region", title="Product A by Region")
chart_add_legend(1)
chart_add_tooltip(1)

# Also show overall stats
df_describe(df)
''',
  ),
  Example(
    name: 'Statistics & Correlation',
    code: '''
csv = """height,weight,age
170,65,25
175,72,30
160,55,22
180,80,35
165,60,28
185,85,40
155,50,20
172,68,32
178,78,38
168,63,26"""

df = df_from_csv(csv)

# Summary statistics
stats = df_describe(df)

# Correlation matrix
corr = df_corr(df)
corr_list = df_to_list(corr)

# Scatter of height vs weight
chart_scatter(df, "height", "weight", title="Height vs Weight")
chart_add_tooltip(1)

corr_list
''',
  ),
  Example(
    name: 'Bubble Chart',
    code: '''
df = df_create([
  {"country": "US", "gdp": 25, "population": 330, "area": 9.8},
  {"country": "China", "gdp": 18, "population": 1400, "area": 9.6},
  {"country": "Japan", "gdp": 5, "population": 125, "area": 0.38},
  {"country": "Germany", "gdp": 4.2, "population": 84, "area": 0.36},
  {"country": "UK", "gdp": 3.1, "population": 67, "area": 0.24},
  {"country": "India", "gdp": 3.7, "population": 1400, "area": 3.3},
  {"country": "France", "gdp": 2.8, "population": 68, "area": 0.64},
  {"country": "Brazil", "gdp": 2.1, "population": 214, "area": 8.5},
])

chart_bubble(df, "gdp", "population", "area", title="GDP vs Population (size=area)")
chart_add_tooltip(1)
''',
  ),
];
